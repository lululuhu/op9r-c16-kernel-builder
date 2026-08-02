# AnyKernel3 Ramdisk Mod Script
# Oblivionis-kernel for OnePlus 9R (lemonades / SM8250)
## AnyKernel setup
# global properties
properties() { '
kernel.string=Oblivionis-kernel for OnePlus 9R
do.devicecheck=1
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=lemonades
device.name2=OnePlus9R
device.name3=OP595DL1
device.name4=OP59BLL1
device.name5=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties
### AnyKernel install
## boot files attributes
boot_attributes() {
set_perm_recursive 0 0 755 644 $RAMDISK/*;
set_perm_recursive 0 0 750 750 $RAMDISK/init* $RAMDISK/sbin;
} # end attributes
# boot shell variables
BLOCK=auto;
IS_SLOT_DEVICE=auto;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;
# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh;
# boot install
dump_boot;

# ---- Oblivionis: 注入运行时调参 ----
# 方案: 将 init.oblivionis.rc 注入 ramdisk，并 patch init.rc 添加 import
ui_print "- Injecting Oblivionis runtime tuning...";

# 1. 确保 init.oblivionis.rc 在 ramdisk 中
if [ -f "$RAMDISK/init.oblivionis.rc" ]; then
  ui_print "  init.oblivionis.rc already in ramdisk";
else
  ui_print "  WARNING: init.oblivionis.rc not found in ramdisk!";
  ui_print "  Runtime tuning will not be applied.";
fi;

# 1b. 确保智能调参脚本在 ramdisk 中并设置可执行权限
if [ -f "$RAMDISK/oblivionis-tuner.sh" ]; then
  set_perm 0 0 755 $RAMDISK/oblivionis-tuner.sh;
  ui_print "  oblivionis-tuner.sh injected (mode 755)";
else
  ui_print "  WARNING: oblivionis-tuner.sh not found!";
  ui_print "  Smart mode switching will not be available.";
fi;

# 2. Patch init.rc 添加 import 行 (确保 init 会执行我们的 .rc)
INIT_RC="$RAMDISK/init.rc";
if [ -f "$INIT_RC" ]; then
  if grep -q "init.oblivionis.rc" "$INIT_RC"; then
    ui_print "  import already present in init.rc";
  else
    # 在 init.rc 末尾添加 import (在 early-init 之前插入更安全)
    # 使用 sed 在第一个 "on early-init" 之前插入 import
    sed -i '1i import /init.oblivionis.rc' "$INIT_RC";
    ui_print "  import /init.oblivionis.rc added to init.rc";
  fi;
else
  ui_print "  WARNING: init.rc not found, trying init.*.rc";
  # 某些设备用 init.<device>.rc
  for f in "$RAMDISK"/init.*.rc; do
    if [ -f "$f" ]; then
      if ! grep -q "init.oblivionis.rc" "$f"; then
        sed -i '1i import /init.oblivionis.rc' "$f";
        ui_print "  import added to $(basename "$f")";
      fi;
      break;
    fi;
  done;
fi;

write_boot;
## end boot install
