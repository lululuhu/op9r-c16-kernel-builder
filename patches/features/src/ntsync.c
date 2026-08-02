// SPDX-License-Identifier: GPL-2.0
/*
 * ntsync.c - NT 同步原语内核驱动 (Linux 4.19 兼容)
 *
 * 功能说明:
 *   提供 Windows NT 同步原语(事件、信号量、互斥体)的内核侧实现，
 *   用于 Wine/Proton 在 Linux 上运行 Windows 应用时的同步模拟。
 *
 *   - 通过 misc device "ntsync" 暴露设备接口
 *   - 每个同步原语由一个匿名 inode 文件表示(通过 anon_inode_getfile 创建)
 *   - 支持 ioctl: CREATE_EVENT / CREATE_SEM / CREATE_MUTEX / WAIT_ALL / WAIT_ANY
 *   - wait_all: 等待所有指定对象同时变为可用信号状态(原子操作)
 *   - wait_any: 等待任一指定对象变为可用信号状态
 *
 * 4.19 兼容性说明:
 *   - 使用 anon_inode_getfile + get_unused_fd_flags + fd_install 创建对象文件
 *     (4.19 不支持 5.x 的 FD_PREPARE/fd_prepare_file/fd_publish 宏)
 *   - 使用 misc_register / misc_deregister 而非 module_misc_device (后者为 5.x 宏)
 *   - 使用 kzalloc(sizeof(*x), GFP_KERNEL) 而非 kzalloc_obj() (6.x 宏)
 *   - 使用 kmalloc(sizeof(*q) + n * sizeof(q->entries[0]), GFP_KERNEL)
 *     而非 kmalloc_flex() (6.x 宏)
 *   - compat_ptr_ioctl 不可用(5.10+)，手动实现 compat_ioctl
 *   - timens_ktime_to_host 不可用(5.6+)，通过 #ifdef 保护，直接使用 timeout
 *   - lockdep_assert 不可用，使用 lockdep_assert_held 或省略
 *   - 所有结构体和 ioctl 定义均在文件内部，不依赖外部 uapi 头文件
 */

#include <linux/module.h>
#include <linux/miscdevice.h>
#include <linux/anon_inodes.h>
#include <linux/file.h>
#include <linux/fs.h>
#include <linux/slab.h>
#include <linux/mutex.h>
#include <linux/spinlock.h>
#include <linux/sched.h>
#include <linux/sched/signal.h>
#include <linux/hrtimer.h>
#include <linux/ktime.h>
#include <linux/atomic.h>
#include <linux/uaccess.h>
#include <linux/overflow.h>

#ifdef CONFIG_COMPAT
#include <linux/compat.h>
#endif

/* ---- 设备名称 ---- */
#define NTSYNC_NAME	"ntsync"

/* ====================================================================
 * 结构体与 ioctl 定义(文件内部定义，不依赖外部 uapi 头文件)
 * ==================================================================== */

/* NT 同步原语类型 */
enum ntsync_type {
	NTSYNC_TYPE_SEM,	/* 信号量 */
	NTSYNC_TYPE_MUTEX,	/* 互斥体 */
	NTSYNC_TYPE_EVENT,	/* 事件 */
};

/* 信号量参数 */
struct ntsync_sem_args {
	__u32 count;	/* 当前计数 */
	__u32 max;	/* 最大计数 */
};

/* 互斥体参数 */
struct ntsync_mutex_args {
	__u32 owner;	/* 持有者 PID */
	__u32 count;	/* 递归计数 */
};

/* 事件参数 */
struct ntsync_event_args {
	__u32 manual;	/* 是否为手动复位事件 */
	__u32 signaled;	/* 是否已触发 */
};

/* 等待操作的标志 */
#define NTSYNC_WAIT_REALTIME	0x1

/* 等待操作参数 */
struct ntsync_wait_args {
	__u64 timeout;	/* 超时时间(纳秒)，U64_MAX 表示无限等待 */
	__u64 objs;	/* 指向 fd 数组的用户空间指针 */
	__u32 count;	/* fd 数组元素个数 */
	__u32 index;	/* [输出] 被触发的对象索引 */
	__u32 flags;	/* 标志(NTSYNC_WAIT_REALTIME) */
	__u32 owner;	/* 等待者 PID(用于互斥体) */
	__u32 alert;	/* 可选的 alert 事件 fd(0 表示无) */
	__u32 pad;	/* 填充 */
};

/* 最大等待对象数 */
#define NTSYNC_MAX_WAIT_COUNT 64

/* 设备级 ioctl 命令(通过 /dev/ntsync 设备 fd 调用) */
#define NTSYNC_IOC_CREATE_SEM		_IOW ('N', 0x80, struct ntsync_sem_args)
#define NTSYNC_IOC_WAIT_ANY		_IOWR('N', 0x82, struct ntsync_wait_args)
#define NTSYNC_IOC_WAIT_ALL		_IOWR('N', 0x83, struct ntsync_wait_args)
#define NTSYNC_IOC_CREATE_MUTEX		_IOW ('N', 0x84, struct ntsync_mutex_args)
#define NTSYNC_IOC_CREATE_EVENT		_IOW ('N', 0x87, struct ntsync_event_args)

/* 对象级 ioctl 命令(通过 create_* 返回的对象 fd 调用) */
#define NTSYNC_IOC_SEM_RELEASE		_IOWR('N', 0x81, __u32)
#define NTSYNC_IOC_MUTEX_UNLOCK		_IOWR('N', 0x85, struct ntsync_mutex_args)
#define NTSYNC_IOC_MUTEX_KILL		_IOW ('N', 0x86, __u32)
#define NTSYNC_IOC_EVENT_SET		_IOR ('N', 0x88, __u32)
#define NTSYNC_IOC_EVENT_RESET		_IOR ('N', 0x89, __u32)
#define NTSYNC_IOC_EVENT_PULSE		_IOR ('N', 0x8a, __u32)
#define NTSYNC_IOC_SEM_READ		_IOR ('N', 0x8b, struct ntsync_sem_args)
#define NTSYNC_IOC_MUTEX_READ		_IOR ('N', 0x8c, struct ntsync_mutex_args)
#define NTSYNC_IOC_EVENT_READ		_IOR ('N', 0x8d, struct ntsync_event_args)

/* ====================================================================
 * 核心数据结构
 * ==================================================================== */

/*
 * 单个同步原语对象，由一个 struct file 支撑(匿名 inode)。
 * 引用计数由 struct file 的 f_count 管理。
 */
struct ntsync_obj {
	spinlock_t lock;
	int dev_locked;		/* 是否被 wait_all 操作锁定 */

	enum ntsync_type type;

	struct file *file;	/* 对应的 struct file */
	struct ntsync_device *dev;

	/* 以下字段受对象自旋锁保护 */
	union {
		struct {
			__u32 count;
			__u32 max;
		} sem;
		struct {
			__u32 count;
			pid_t owner;
			bool ownerdead;
		} mutex;
		struct {
			bool manual;
			bool signaled;
		} event;
	} u;

	/*
	 * any_waiters 受对象自旋锁保护;
	 * all_waiters 受设备级 wait_all_lock 保护。
	 */
	struct list_head any_waiters;
	struct list_head all_waiters;

	/*
	 * 提示该对象上有多少 wait-all 操作在等待。
	 * 唤醒时若为 0 则跳过 wait-all 唤醒路径(减少锁竞争)。
	 */
	atomic_t all_hint;
};

/* 等待队列条目: 每个被等待的对象对应一个 */
struct ntsync_q_entry {
	struct list_head node;
	struct ntsync_q *q;
	struct ntsync_obj *obj;
	__u32 index;
};

/* 等待队列: 一次 wait_any/wait_all 操作对应一个 */
struct ntsync_q {
	struct task_struct *task;
	__u32 owner;

	/*
	 * 通过 atomic_try_cmpxchg 保护: 只有赢得 CAS 的线程
	 * 才能修改对象状态并唤醒任务。初始值 -1 表示未触发。
	 */
	atomic_t signaled;

	bool all;		/* true=wait_all, false=wait_any */
	bool ownerdead;		/* 互斥体所有者是否已死亡 */
	__u32 count;		/* 等待的对象数(不含 alert) */
	struct ntsync_q_entry entries[];	/* 柔性数组 */
};

/*
 * 设备结构体: 每个 /dev/ntsync fd 对应一个。
 * wait_all_lock 用于序列化 wait-all 操作及涉及 wait-all 的对象操作。
 */
struct ntsync_device {
	struct mutex wait_all_lock;
	struct file *file;
};

/* ====================================================================
 * 锁辅助函数
 *
 * 单个对象通过 obj->lock 加锁。
 * 多个对象(wait-all)通过 dev->wait_all_lock 加锁。
 * 当对象被 wait-all 锁定时，通过设置 obj->dev_locked 标志，
 * 使得单对象加锁路径需要先获取 wait_all_lock。
 * ==================================================================== */

static void dev_lock_obj(struct ntsync_device *dev, struct ntsync_obj *obj)
{
	lockdep_assert_held(&dev->wait_all_lock);
	spin_lock(&obj->lock);
	obj->dev_locked = 1;
	spin_unlock(&obj->lock);
}

static void dev_unlock_obj(struct ntsync_device *dev, struct ntsync_obj *obj)
{
	lockdep_assert_held(&dev->wait_all_lock);
	spin_lock(&obj->lock);
	obj->dev_locked = 0;
	spin_unlock(&obj->lock);
}

static void obj_lock(struct ntsync_obj *obj)
{
	struct ntsync_device *dev = obj->dev;

	for (;;) {
		spin_lock(&obj->lock);
		if (likely(!obj->dev_locked))
			break;

		/* 对象被 wait-all 锁定，需要先获取 wait_all_lock */
		spin_unlock(&obj->lock);
		mutex_lock(&dev->wait_all_lock);
		spin_lock(&obj->lock);
		/* 获取 wait_all_lock 后 dev_locked 应已清除 */
		spin_unlock(&obj->lock);
		mutex_unlock(&dev->wait_all_lock);
	}
}

static void obj_unlock(struct ntsync_obj *obj)
{
	spin_unlock(&obj->lock);
}

/*
 * 智能加锁: 先尝试单对象锁，若发现 all_hint 非零(有 wait-all 等待者)
 * 则升级为 wait_all_lock + dev_lock_obj。
 * 返回 true 表示使用了 wait_all_lock(需要对应解锁方式)。
 */
static bool ntsync_lock_obj(struct ntsync_device *dev, struct ntsync_obj *obj)
{
	bool all;

	obj_lock(obj);
	all = atomic_read(&obj->all_hint);
	if (unlikely(all)) {
		obj_unlock(obj);
		mutex_lock(&dev->wait_all_lock);
		dev_lock_obj(dev, obj);
	}

	return all;
}

static void ntsync_unlock_obj(struct ntsync_device *dev, struct ntsync_obj *obj,
			      bool all)
{
	if (all) {
		dev_unlock_obj(dev, obj);
		mutex_unlock(&dev->wait_all_lock);
	} else {
		obj_unlock(obj);
	}
}

/* ====================================================================
 * 信号判定
 * ==================================================================== */

/* 判断对象是否处于信号状态(已持有锁) */
static bool is_signaled(struct ntsync_obj *obj, __u32 owner)
{
	switch (obj->type) {
	case NTSYNC_TYPE_SEM:
		return !!obj->u.sem.count;
	case NTSYNC_TYPE_MUTEX:
		if (obj->u.mutex.owner && obj->u.mutex.owner != owner)
			return false;
		return obj->u.mutex.count < UINT_MAX;
	case NTSYNC_TYPE_EVENT:
		return obj->u.event.signaled;
	}

	WARN(1, "bad object type %#x\n", obj->type);
	return false;
}

/* ====================================================================
 * 唤醒逻辑
 * ==================================================================== */

/*
 * 尝试唤醒一个 wait-all 队列。
 * locked_obj 是已锁定的对象(可选)，避免重复加锁。
 */
static void try_wake_all(struct ntsync_device *dev, struct ntsync_q *q,
			 struct ntsync_obj *locked_obj)
{
	__u32 count = q->count;
	bool can_wake = true;
	int signaled = -1;
	__u32 i;

	lockdep_assert_held(&dev->wait_all_lock);

	/* 锁定所有对象 */
	for (i = 0; i < count; i++) {
		if (q->entries[i].obj != locked_obj)
			dev_lock_obj(dev, q->entries[i].obj);
	}

	/* 检查是否所有对象都已信号 */
	for (i = 0; i < count; i++) {
		if (!is_signaled(q->entries[i].obj, q->owner)) {
			can_wake = false;
			break;
		}
	}

	/* CAS: 确保只有一个等待者被唤醒 */
	if (can_wake && atomic_try_cmpxchg(&q->signaled, &signaled, 0)) {
		/* 消费信号: 递减信号量/获取互斥体/复位自动事件 */
		for (i = 0; i < count; i++) {
			struct ntsync_obj *obj = q->entries[i].obj;

			switch (obj->type) {
			case NTSYNC_TYPE_SEM:
				obj->u.sem.count--;
				break;
			case NTSYNC_TYPE_MUTEX:
				if (obj->u.mutex.ownerdead)
					q->ownerdead = true;
				obj->u.mutex.ownerdead = false;
				obj->u.mutex.count++;
				obj->u.mutex.owner = q->owner;
				break;
			case NTSYNC_TYPE_EVENT:
				if (!obj->u.event.manual)
					obj->u.event.signaled = false;
				break;
			}
		}
		wake_up_process(q->task);
	}

	/* 解锁所有对象 */
	for (i = 0; i < count; i++) {
		if (q->entries[i].obj != locked_obj)
			dev_unlock_obj(dev, q->entries[i].obj);
	}
}

/* 尝试唤醒对象上所有 wait-all 队列 */
static void try_wake_all_obj(struct ntsync_device *dev, struct ntsync_obj *obj)
{
	struct ntsync_q_entry *entry;

	lockdep_assert_held(&dev->wait_all_lock);

	list_for_each_entry(entry, &obj->all_waiters, node)
		try_wake_all(dev, entry->q, obj);
}

/* 尝试唤醒信号量上的 wait-any 队列 */
static void try_wake_any_sem(struct ntsync_obj *sem)
{
	struct ntsync_q_entry *entry;

	list_for_each_entry(entry, &sem->any_waiters, node) {
		struct ntsync_q *q = entry->q;
		int signaled = -1;

		if (!sem->u.sem.count)
			break;

		if (atomic_try_cmpxchg(&q->signaled, &signaled, entry->index)) {
			sem->u.sem.count--;
			wake_up_process(q->task);
		}
	}
}

/* 尝试唤醒互斥体上的 wait-any 队列 */
static void try_wake_any_mutex(struct ntsync_obj *mutex)
{
	struct ntsync_q_entry *entry;

	list_for_each_entry(entry, &mutex->any_waiters, node) {
		struct ntsync_q *q = entry->q;
		int signaled = -1;

		if (mutex->u.mutex.count == UINT_MAX)
			break;
		if (mutex->u.mutex.owner && mutex->u.mutex.owner != q->owner)
			continue;

		if (atomic_try_cmpxchg(&q->signaled, &signaled, entry->index)) {
			if (mutex->u.mutex.ownerdead)
				q->ownerdead = true;
			mutex->u.mutex.ownerdead = false;
			mutex->u.mutex.count++;
			mutex->u.mutex.owner = q->owner;
			wake_up_process(q->task);
		}
	}
}

/* 尝试唤醒事件上的 wait-any 队列 */
static void try_wake_any_event(struct ntsync_obj *event)
{
	struct ntsync_q_entry *entry;

	list_for_each_entry(entry, &event->any_waiters, node) {
		struct ntsync_q *q = entry->q;
		int signaled = -1;

		if (!event->u.event.signaled)
			break;

		if (atomic_try_cmpxchg(&q->signaled, &signaled, entry->index)) {
			if (!event->u.event.manual)
				event->u.event.signaled = false;
			wake_up_process(q->task);
		}
	}
}

static void try_wake_any_obj(struct ntsync_obj *obj)
{
	switch (obj->type) {
	case NTSYNC_TYPE_SEM:
		try_wake_any_sem(obj);
		break;
	case NTSYNC_TYPE_MUTEX:
		try_wake_any_mutex(obj);
		break;
	case NTSYNC_TYPE_EVENT:
		try_wake_any_event(obj);
		break;
	}
}

/* ====================================================================
 * 对象级操作(信号量/互斥体/事件)
 * ==================================================================== */

/* 信号量释放(增加计数) */
static int ntsync_sem_release(struct ntsync_obj *sem, void __user *argp)
{
	struct ntsync_device *dev = sem->dev;
	__u32 __user *user_args = argp;
	__u32 prev_count;
	__u32 args;
	bool all;
	int ret;
	__u32 sum;

	if (copy_from_user(&args, argp, sizeof(args)))
		return -EFAULT;

	if (sem->type != NTSYNC_TYPE_SEM)
		return -EINVAL;

	all = ntsync_lock_obj(dev, sem);

	prev_count = sem->u.sem.count;

	/* 释放: count += args，检查溢出和上限 */
	if (check_add_overflow(sem->u.sem.count, args, &sum) ||
	    sum > sem->u.sem.max) {
		ret = -EOVERFLOW;
	} else {
		sem->u.sem.count = sum;
		ret = 0;
	}

	if (!ret) {
		if (all)
			try_wake_all_obj(dev, sem);
		try_wake_any_sem(sem);
	}

	ntsync_unlock_obj(dev, sem, all);

	if (!ret && put_user(prev_count, user_args))
		ret = -EFAULT;

	return ret;
}

/* 互斥体解锁 */
static int ntsync_mutex_unlock(struct ntsync_obj *mutex, void __user *argp)
{
	struct ntsync_mutex_args __user *user_args = argp;
	struct ntsync_device *dev = mutex->dev;
	struct ntsync_mutex_args args;
	__u32 prev_count;
	bool all;
	int ret;

	if (copy_from_user(&args, argp, sizeof(args)))
		return -EFAULT;
	if (!args.owner)
		return -EINVAL;

	if (mutex->type != NTSYNC_TYPE_MUTEX)
		return -EINVAL;

	all = ntsync_lock_obj(dev, mutex);

	prev_count = mutex->u.mutex.count;

	/* 验证调用者是否为持有者 */
	if (mutex->u.mutex.owner != args.owner) {
		ret = -EPERM;
	} else {
		if (!--mutex->u.mutex.count)
			mutex->u.mutex.owner = 0;
		ret = 0;
	}

	if (!ret) {
		if (all)
			try_wake_all_obj(dev, mutex);
		try_wake_any_mutex(mutex);
	}

	ntsync_unlock_obj(dev, mutex, all);

	if (!ret && put_user(prev_count, &user_args->count))
		ret = -EFAULT;

	return ret;
}

/* 互斥体 kill: 标记所有者为死亡 */
static int ntsync_mutex_kill(struct ntsync_obj *mutex, void __user *argp)
{
	struct ntsync_device *dev = mutex->dev;
	__u32 owner;
	bool all;
	int ret;

	if (get_user(owner, (__u32 __user *)argp))
		return -EFAULT;
	if (!owner)
		return -EINVAL;

	if (mutex->type != NTSYNC_TYPE_MUTEX)
		return -EINVAL;

	all = ntsync_lock_obj(dev, mutex);

	if (mutex->u.mutex.owner != owner) {
		ret = -EPERM;
	} else {
		mutex->u.mutex.ownerdead = true;
		mutex->u.mutex.owner = 0;
		mutex->u.mutex.count = 0;
		ret = 0;
	}

	if (!ret) {
		if (all)
			try_wake_all_obj(dev, mutex);
		try_wake_any_mutex(mutex);
	}

	ntsync_unlock_obj(dev, mutex, all);

	return ret;
}

/* 事件触发(set) */
static int ntsync_event_set(struct ntsync_obj *event, void __user *argp,
			    bool pulse)
{
	struct ntsync_device *dev = event->dev;
	__u32 prev_state;
	bool all;

	if (event->type != NTSYNC_TYPE_EVENT)
		return -EINVAL;

	all = ntsync_lock_obj(dev, event);

	prev_state = event->u.event.signaled;
	event->u.event.signaled = true;
	if (all)
		try_wake_all_obj(dev, event);
	try_wake_any_event(event);
	if (pulse)
		event->u.event.signaled = false;

	ntsync_unlock_obj(dev, event, all);

	if (put_user(prev_state, (__u32 __user *)argp))
		return -EFAULT;

	return 0;
}

/* 事件复位(reset) */
static int ntsync_event_reset(struct ntsync_obj *event, void __user *argp)
{
	struct ntsync_device *dev = event->dev;
	__u32 prev_state;
	bool all;

	if (event->type != NTSYNC_TYPE_EVENT)
		return -EINVAL;

	all = ntsync_lock_obj(dev, event);

	prev_state = event->u.event.signaled;
	event->u.event.signaled = false;

	ntsync_unlock_obj(dev, event, all);

	if (put_user(prev_state, (__u32 __user *)argp))
		return -EFAULT;

	return 0;
}

/* 读取信号量状态 */
static int ntsync_sem_read(struct ntsync_obj *sem, void __user *argp)
{
	struct ntsync_sem_args __user *user_args = argp;
	struct ntsync_device *dev = sem->dev;
	struct ntsync_sem_args args;
	bool all;

	if (sem->type != NTSYNC_TYPE_SEM)
		return -EINVAL;

	all = ntsync_lock_obj(dev, sem);

	args.count = sem->u.sem.count;
	args.max = sem->u.sem.max;

	ntsync_unlock_obj(dev, sem, all);

	if (copy_to_user(user_args, &args, sizeof(args)))
		return -EFAULT;
	return 0;
}

/* 读取互斥体状态 */
static int ntsync_mutex_read(struct ntsync_obj *mutex, void __user *argp)
{
	struct ntsync_mutex_args __user *user_args = argp;
	struct ntsync_device *dev = mutex->dev;
	struct ntsync_mutex_args args;
	bool all;
	int ret;

	if (mutex->type != NTSYNC_TYPE_MUTEX)
		return -EINVAL;

	all = ntsync_lock_obj(dev, mutex);

	args.count = mutex->u.mutex.count;
	args.owner = mutex->u.mutex.owner;
	ret = mutex->u.mutex.ownerdead ? -EOWNERDEAD : 0;

	ntsync_unlock_obj(dev, mutex, all);

	if (copy_to_user(user_args, &args, sizeof(args)))
		return -EFAULT;
	return ret;
}

/* 读取事件状态 */
static int ntsync_event_read(struct ntsync_obj *event, void __user *argp)
{
	struct ntsync_event_args __user *user_args = argp;
	struct ntsync_device *dev = event->dev;
	struct ntsync_event_args args;
	bool all;

	if (event->type != NTSYNC_TYPE_EVENT)
		return -EINVAL;

	all = ntsync_lock_obj(dev, event);

	args.manual = event->u.event.manual;
	args.signaled = event->u.event.signaled;

	ntsync_unlock_obj(dev, event, all);

	if (copy_to_user(user_args, &args, sizeof(args)))
		return -EFAULT;
	return 0;
}

/* ====================================================================
 * 对象文件操作
 * ==================================================================== */

static void ntsync_free_obj(struct ntsync_obj *obj)
{
	fput(obj->dev->file);
	kfree(obj);
}

static int ntsync_obj_release(struct inode *inode, struct file *file)
{
	ntsync_free_obj(file->private_data);
	return 0;
}

static long ntsync_obj_ioctl(struct file *file, unsigned int cmd,
			     unsigned long parm)
{
	struct ntsync_obj *obj = file->private_data;
	void __user *argp = (void __user *)parm;

	switch (cmd) {
	case NTSYNC_IOC_SEM_RELEASE:
		return ntsync_sem_release(obj, argp);
	case NTSYNC_IOC_SEM_READ:
		return ntsync_sem_read(obj, argp);
	case NTSYNC_IOC_MUTEX_UNLOCK:
		return ntsync_mutex_unlock(obj, argp);
	case NTSYNC_IOC_MUTEX_KILL:
		return ntsync_mutex_kill(obj, argp);
	case NTSYNC_IOC_MUTEX_READ:
		return ntsync_mutex_read(obj, argp);
	case NTSYNC_IOC_EVENT_SET:
		return ntsync_event_set(obj, argp, false);
	case NTSYNC_IOC_EVENT_RESET:
		return ntsync_event_reset(obj, argp);
	case NTSYNC_IOC_EVENT_PULSE:
		return ntsync_event_set(obj, argp, true);
	case NTSYNC_IOC_EVENT_READ:
		return ntsync_event_read(obj, argp);
	default:
		return -ENOIOCTLCMD;
	}
}

static const struct file_operations ntsync_obj_fops = {
	.owner		= THIS_MODULE,
	.release	= ntsync_obj_release,
	.unlocked_ioctl	= ntsync_obj_ioctl,
#ifdef CONFIG_COMPAT
	.compat_ioctl	= ntsync_obj_ioctl,
#endif
};

/* ====================================================================
 * 对象创建
 * ==================================================================== */

static struct ntsync_obj *ntsync_alloc_obj(struct ntsync_device *dev,
					   enum ntsync_type type)
{
	struct ntsync_obj *obj;

	/* 4.19: 使用 kzalloc 而非 kzalloc_obj */
	obj = kzalloc(sizeof(*obj), GFP_KERNEL);
	if (!obj)
		return NULL;

	obj->type = type;
	obj->dev = dev;
	get_file(dev->file);	/* 设备文件引用计数 */
	spin_lock_init(&obj->lock);
	INIT_LIST_HEAD(&obj->any_waiters);
	INIT_LIST_HEAD(&obj->all_waiters);
	atomic_set(&obj->all_hint, 0);

	return obj;
}

/*
 * 4.19 兼容: 使用 anon_inode_getfile + get_unused_fd_flags + fd_install
 * 创建对象文件并返回 fd。
 * (5.x 使用 FD_PREPARE/fd_prepare_file/fd_publish 宏，4.19 不可用)
 */
static int ntsync_obj_get_fd(struct ntsync_obj *obj)
{
	struct file *file;
	int fd;

	fd = get_unused_fd_flags(O_RDWR | O_CLOEXEC);
	if (fd < 0)
		return fd;

	/* 4.19: anon_inode_getfile 创建匿名 inode 文件 */
	file = anon_inode_getfile("ntsync", &ntsync_obj_fops, obj, O_RDWR);
	if (IS_ERR(file)) {
		put_unused_fd(fd);
		return PTR_ERR(file);
	}

	obj->file = file;
	fd_install(fd, file);
	return fd;
}

static int ntsync_create_sem(struct ntsync_device *dev, void __user *argp)
{
	struct ntsync_sem_args args;
	struct ntsync_obj *sem;
	int fd;

	if (copy_from_user(&args, argp, sizeof(args)))
		return -EFAULT;

	if (args.count > args.max)
		return -EINVAL;

	sem = ntsync_alloc_obj(dev, NTSYNC_TYPE_SEM);
	if (!sem)
		return -ENOMEM;
	sem->u.sem.count = args.count;
	sem->u.sem.max = args.max;

	fd = ntsync_obj_get_fd(sem);
	if (fd < 0)
		ntsync_free_obj(sem);

	return fd;
}

static int ntsync_create_mutex(struct ntsync_device *dev, void __user *argp)
{
	struct ntsync_mutex_args args;
	struct ntsync_obj *mutex;
	int fd;

	if (copy_from_user(&args, argp, sizeof(args)))
		return -EFAULT;

	/* owner 和 count 必须同时为零或同时非零 */
	if (!args.owner != !args.count)
		return -EINVAL;

	mutex = ntsync_alloc_obj(dev, NTSYNC_TYPE_MUTEX);
	if (!mutex)
		return -ENOMEM;
	mutex->u.mutex.count = args.count;
	mutex->u.mutex.owner = args.owner;

	fd = ntsync_obj_get_fd(mutex);
	if (fd < 0)
		ntsync_free_obj(mutex);

	return fd;
}

static int ntsync_create_event(struct ntsync_device *dev, void __user *argp)
{
	struct ntsync_event_args args;
	struct ntsync_obj *event;
	int fd;

	if (copy_from_user(&args, argp, sizeof(args)))
		return -EFAULT;

	event = ntsync_alloc_obj(dev, NTSYNC_TYPE_EVENT);
	if (!event)
		return -ENOMEM;
	event->u.event.manual = args.manual;
	event->u.event.signaled = args.signaled;

	fd = ntsync_obj_get_fd(event);
	if (fd < 0)
		ntsync_free_obj(event);

	return fd;
}

/* ====================================================================
 * 等待操作
 * ==================================================================== */

/* 通过 fd 获取对象(增加引用计数) */
static struct ntsync_obj *get_obj(struct ntsync_device *dev, int fd)
{
	struct file *file = fget(fd);
	struct ntsync_obj *obj;

	if (!file)
		return NULL;

	if (file->f_op != &ntsync_obj_fops) {
		fput(file);
		return NULL;
	}

	obj = file->private_data;
	if (obj->dev != dev) {
		fput(file);
		return NULL;
	}

	return obj;
}

static void put_obj(struct ntsync_obj *obj)
{
	fput(obj->file);
}

/*
 * 等待调度: 将当前任务设为可中断睡眠，直到被唤醒或超时。
 */
static int ntsync_schedule(const struct ntsync_q *q,
			   const struct ntsync_wait_args *args)
{
	ktime_t timeout = ns_to_ktime(args->timeout);
	clockid_t clock = CLOCK_MONOTONIC;
	ktime_t *timeout_ptr;
	int ret = 0;

	timeout_ptr = (args->timeout == U64_MAX ? NULL : &timeout);

	if (args->flags & NTSYNC_WAIT_REALTIME)
		clock = CLOCK_REALTIME;
#ifdef CONFIG_TIME_NS
	else
		timeout = timens_ktime_to_host(clock, timeout);
#endif

	do {
		if (signal_pending(current)) {
			ret = -ERESTARTSYS;
			break;
		}

		set_current_state(TASK_INTERRUPTIBLE);
		if (atomic_read(&q->signaled) != -1) {
			ret = 0;
			break;
		}
		ret = schedule_hrtimeout_range_clock(timeout_ptr, 0,
						     HRTIMER_MODE_ABS, clock);
	} while (ret < 0);
	__set_current_state(TASK_RUNNING);

	return ret;
}

/*
 * 分配并初始化等待队列(但不入队)。
 */
static int setup_wait(struct ntsync_device *dev,
		      const struct ntsync_wait_args *args, bool all,
		      struct ntsync_q **ret_q)
{
	int fds[NTSYNC_MAX_WAIT_COUNT + 1];
	const __u32 count = args->count;
	size_t size = count * sizeof(fds[0]);
	struct ntsync_q *q;
	__u32 total_count;
	__u32 i, j;

	if (args->pad || (args->flags & ~NTSYNC_WAIT_REALTIME))
		return -EINVAL;

	if (size >= sizeof(fds))
		return -EINVAL;

	total_count = count;
	if (args->alert)
		total_count++;

	if (copy_from_user(fds, (void __user *)args->objs, size))
		return -EFAULT;
	if (args->alert)
		fds[count] = args->alert;

	/* 4.19: 使用 kmalloc + 手动大小计算，而非 kmalloc_flex */
	q = kmalloc(sizeof(*q) + total_count * sizeof(q->entries[0]),
		    GFP_KERNEL);
	if (!q)
		return -ENOMEM;

	q->task = current;
	q->owner = args->owner;
	atomic_set(&q->signaled, -1);
	q->all = all;
	q->ownerdead = false;
	q->count = count;

	for (i = 0; i < total_count; i++) {
		struct ntsync_q_entry *entry = &q->entries[i];
		struct ntsync_obj *obj = get_obj(dev, fds[i]);

		if (!obj)
			goto err;

		if (all) {
			/* wait-all: 检查对象是否互异 */
			for (j = 0; j < i; j++) {
				if (obj == q->entries[j].obj) {
					put_obj(obj);
					goto err;
				}
			}
		}

		entry->obj = obj;
		entry->q = q;
		entry->index = i;
	}

	*ret_q = q;
	return 0;

err:
	for (j = 0; j < i; j++)
		put_obj(q->entries[j].obj);
	kfree(q);
	return -EINVAL;
}

/*
 * WAIT_ANY: 等待任一对象变为信号状态。
 */
static int ntsync_wait_any(struct ntsync_device *dev, void __user *argp)
{
	struct ntsync_wait_args args;
	__u32 i, total_count;
	struct ntsync_q *q;
	int signaled;
	bool all;
	int ret;

	if (copy_from_user(&args, argp, sizeof(args)))
		return -EFAULT;

	ret = setup_wait(dev, &args, false, &q);
	if (ret < 0)
		return ret;

	total_count = args.count;
	if (args.alert)
		total_count++;

	/* 将自己加入每个对象的 any_waiters 队列 */
	for (i = 0; i < total_count; i++) {
		struct ntsync_q_entry *entry = &q->entries[i];
		struct ntsync_obj *obj = entry->obj;

		all = ntsync_lock_obj(dev, obj);
		list_add_tail(&entry->node, &obj->any_waiters);
		ntsync_unlock_obj(dev, obj, all);
	}

	/* 检查是否已有信号(alert 最后检查) */
	for (i = 0; i < total_count; i++) {
		struct ntsync_obj *obj = q->entries[i].obj;

		if (atomic_read(&q->signaled) != -1)
			break;

		all = ntsync_lock_obj(dev, obj);
		try_wake_any_obj(obj);
		ntsync_unlock_obj(dev, obj, all);
	}

	/* 睡眠等待 */
	ret = ntsync_schedule(q, &args);

	/* 从所有对象的 any_waiters 中移除 */
	for (i = 0; i < total_count; i++) {
		struct ntsync_q_entry *entry = &q->entries[i];
		struct ntsync_obj *obj = entry->obj;

		all = ntsync_lock_obj(dev, obj);
		list_del(&entry->node);
		ntsync_unlock_obj(dev, obj, all);

		put_obj(obj);
	}

	signaled = atomic_read(&q->signaled);
	if (signaled != -1) {
		struct ntsync_wait_args __user *user_args = argp;

		/* 即使收到信号也要报告成功 */
		ret = q->ownerdead ? -EOWNERDEAD : 0;

		if (put_user(signaled, &user_args->index))
			ret = -EFAULT;
	} else if (!ret) {
		ret = -ETIMEDOUT;
	}

	kfree(q);
	return ret;
}

/*
 * WAIT_ALL: 等待所有对象同时变为信号状态(原子操作)。
 */
static int ntsync_wait_all(struct ntsync_device *dev, void __user *argp)
{
	struct ntsync_wait_args args;
	struct ntsync_q *q;
	int signaled;
	__u32 i;
	int ret;

	if (copy_from_user(&args, argp, sizeof(args)))
		return -EFAULT;

	ret = setup_wait(dev, &args, true, &q);
	if (ret < 0)
		return ret;

	/* 加锁 wait_all_lock，原子地将自己加入所有对象 */
	mutex_lock(&dev->wait_all_lock);

	for (i = 0; i < args.count; i++) {
		struct ntsync_q_entry *entry = &q->entries[i];
		struct ntsync_obj *obj = entry->obj;

		atomic_inc(&obj->all_hint);

		/* all_waiters 受 wait_all_lock 保护，无需 obj->lock */
		list_add_tail(&entry->node, &obj->all_waiters);
	}

	/* alert 事件加入 any_waiters(需要 dev_lock_obj) */
	if (args.alert) {
		struct ntsync_q_entry *entry = &q->entries[args.count];
		struct ntsync_obj *obj = entry->obj;

		dev_lock_obj(dev, obj);
		list_add_tail(&entry->node, &obj->any_waiters);
		dev_unlock_obj(dev, obj);
	}

	/* 检查是否已满足条件 */
	try_wake_all(dev, q, NULL);

	mutex_unlock(&dev->wait_all_lock);

	/* 检查 alert 事件是否已信号 */
	if (args.alert) {
		struct ntsync_obj *obj = q->entries[args.count].obj;

		if (atomic_read(&q->signaled) == -1) {
			bool all = ntsync_lock_obj(dev, obj);
			try_wake_any_obj(obj);
			ntsync_unlock_obj(dev, obj, all);
		}
	}

	/* 睡眠等待 */
	ret = ntsync_schedule(q, &args);

	/* 从所有对象中移除 */
	mutex_lock(&dev->wait_all_lock);

	for (i = 0; i < args.count; i++) {
		struct ntsync_q_entry *entry = &q->entries[i];
		struct ntsync_obj *obj = entry->obj;

		list_del(&entry->node);
		atomic_dec(&obj->all_hint);
		put_obj(obj);
	}

	mutex_unlock(&dev->wait_all_lock);

	if (args.alert) {
		struct ntsync_q_entry *entry = &q->entries[args.count];
		struct ntsync_obj *obj = entry->obj;
		bool all;

		all = ntsync_lock_obj(dev, obj);
		list_del(&entry->node);
		ntsync_unlock_obj(dev, obj, all);

		put_obj(obj);
	}

	signaled = atomic_read(&q->signaled);
	if (signaled != -1) {
		struct ntsync_wait_args __user *user_args = argp;

		ret = q->ownerdead ? -EOWNERDEAD : 0;

		if (put_user(signaled, &user_args->index))
			ret = -EFAULT;
	} else if (!ret) {
		ret = -ETIMEDOUT;
	}

	kfree(q);
	return ret;
}

/* ====================================================================
 * 设备文件操作
 * ==================================================================== */

static int ntsync_char_open(struct inode *inode, struct file *file)
{
	struct ntsync_device *dev;

	/* 4.19: 使用 kzalloc 而非 kzalloc_obj */
	dev = kzalloc(sizeof(*dev), GFP_KERNEL);
	if (!dev)
		return -ENOMEM;

	mutex_init(&dev->wait_all_lock);

	file->private_data = dev;
	dev->file = file;
	return nonseekable_open(inode, file);
}

static int ntsync_char_release(struct inode *inode, struct file *file)
{
	struct ntsync_device *dev = file->private_data;

	kfree(dev);
	return 0;
}

static long ntsync_char_ioctl(struct file *file, unsigned int cmd,
			      unsigned long parm)
{
	struct ntsync_device *dev = file->private_data;
	void __user *argp = (void __user *)parm;

	switch (cmd) {
	case NTSYNC_IOC_CREATE_EVENT:
		return ntsync_create_event(dev, argp);
	case NTSYNC_IOC_CREATE_MUTEX:
		return ntsync_create_mutex(dev, argp);
	case NTSYNC_IOC_CREATE_SEM:
		return ntsync_create_sem(dev, argp);
	case NTSYNC_IOC_WAIT_ALL:
		return ntsync_wait_all(dev, argp);
	case NTSYNC_IOC_WAIT_ANY:
		return ntsync_wait_any(dev, argp);
	default:
		return -ENOIOCTLCMD;
	}
}

static const struct file_operations ntsync_fops = {
	.owner		= THIS_MODULE,
	.open		= ntsync_char_open,
	.release	= ntsync_char_release,
	.unlocked_ioctl	= ntsync_char_ioctl,
#ifdef CONFIG_COMPAT
	.compat_ioctl	= ntsync_char_ioctl,
#endif
};

/* ====================================================================
 * Misc 设备注册
 * ==================================================================== */

static struct miscdevice ntsync_misc = {
	.minor	= MISC_DYNAMIC_MINOR,
	.name	= NTSYNC_NAME,
	.fops	= &ntsync_fops,
	.mode	= 0666,
};

static int __init ntsync_init(void)
{
	int ret;

	/* 4.19: 使用 misc_register 而非 module_misc_device 宏 */
	ret = misc_register(&ntsync_misc);
	if (ret) {
		pr_err("ntsync: misc_register 失败: %d\n", ret);
		return ret;
	}

	pr_info("ntsync: NT 同步原语驱动已加载(4.19 兼容)\n");
	return 0;
}

static void __exit ntsync_exit(void)
{
	misc_deregister(&ntsync_misc);
	pr_info("ntsync: NT 同步原语驱动已卸载\n");
}

module_init(ntsync_init);
module_exit(ntsync_exit);

MODULE_AUTHOR("Oblivionis-kernel project");
MODULE_DESCRIPTION("NTSYNC: NT synchronization primitives driver for Wine/Proton (4.19 compat)");
MODULE_LICENSE("GPL");
MODULE_VERSION("1.0-4.19");
