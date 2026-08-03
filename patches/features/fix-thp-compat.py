#!/usr/bin/env python3
"""
fix-thp-compat.py — Fix THP API mismatches in vendor 4.19 kernel

The LineageOS SM8250 4.19 vendor kernel cherry-picked newer mainline API
changes to header files (rmap.h, mmu_notifier.h) but did NOT update all
callers (huge_memory.c, khugepaged.c). This script fixes the callers to
match the updated API.

Issues fixed:
  1. try_to_unmap() — vendor kernel added a 3rd argument, callers still use 2
  2. mmu_notifier_invalidate_range_start/end() — vendor kernel changed to
     struct-based API, callers still use old 3-argument API
  3. maybe_mkwrite() — vendor kernel changed to take vma_flags (unsigned long)
     instead of vma (struct vm_area_struct *)

Exit codes:
  0 — all fixes applied successfully (or files not found, nothing to do)
  1 — a fix failed; caller should disable THP as fallback
"""

import re
import os
import sys

def read_file(path):
    with open(path, 'r') as f:
        return f.read()

def write_file(path, content):
    with open(path, 'w') as f:
        f.write(content)

def fix_try_to_unmap(kernel_dir):
    """Fix try_to_unmap() calls in huge_memory.c to match vendor kernel's 3-arg API."""
    rmap_path = os.path.join(kernel_dir, 'include/linux/rmap.h')
    huge_path = os.path.join(kernel_dir, 'mm/huge_memory.c')

    if not os.path.exists(huge_path):
        print("[THP-FIX] huge_memory.c not found, skipping try_to_unmap fix")
        return True

    content = read_file(huge_path)

    # Check if the old 2-arg call exists
    old_pattern = r'try_to_unmap\s*\(\s*page\s*,\s*ttu_flags\s*\)'
    if not re.search(old_pattern, content):
        print("[THP-FIX] try_to_unmap 2-arg call not found in huge_memory.c (already fixed?)")
        return True

    # Find the third parameter from rmap.h declaration
    third_arg_default = 'NULL'  # Safe default for pointer types

    if os.path.exists(rmap_path):
        rmap_content = read_file(rmap_path)
        # Find try_to_unmap declaration (may span multiple lines)
        # Pattern: bool try_to_unmap(struct page *page, enum ttu_flags flags, ...);
        match = re.search(
            r'(?:bool|int|void)\s+try_to_unmap\s*\(([^)]+)\)',
            rmap_content,
            re.DOTALL
        )
        if match:
            params_str = match.group(1)
            # Split by comma, handling pointers
            params = [p.strip() for p in params_str.split(',')]
            if len(params) >= 3:
                # Get the third parameter name (last word, removing * and ;)
                third_param = params[2].strip()
                # Extract just the variable name
                parts = third_param.split()
                if parts:
                    var_name = parts[-1].rstrip('*;&')
                    # Check if it's a pointer type
                    is_pointer = '*' in third_param
                    if is_pointer:
                        third_arg_default = 'NULL'
                    elif 'bool' in third_param:
                        third_arg_default = 'false'
                    else:
                        third_arg_default = 'NULL'
                    print(f"[THP-FIX] try_to_unmap 3rd param: '{third_param}' -> using '{third_arg_default}'")
                else:
                    print(f"[THP-FIX] Could not parse 3rd param, using NULL")
            else:
                print(f"[THP-FIX] try_to_unmap has {len(params)} params in rmap.h, using NULL")
        else:
            print("[THP-FIX] Could not find try_to_unmap declaration in rmap.h, using NULL")
    else:
        print("[THP-FIX] rmap.h not found, using NULL as 3rd arg")

    # Replace all 2-arg calls with 3-arg calls
    new_content = re.sub(
        r'try_to_unmap\s*\(\s*page\s*,\s*ttu_flags\s*\)',
        f'try_to_unmap(page, ttu_flags, {third_arg_default})',
        content
    )

    if new_content != content:
        write_file(huge_path, new_content)
        print(f"[THP-FIX] Fixed try_to_unmap in huge_memory.c (3rd arg: {third_arg_default})")
        return True
    else:
        print("[THP-FIX] WARNING: try_to_unmap pattern did not match, fix may have failed")
        return False


def fix_mmu_notifier(kernel_dir):
    """Fix mmu_notifier_invalidate_range_start/end() calls in khugepaged.c."""
    khuge_path = os.path.join(kernel_dir, 'mm/khugepaged.c')
    notifier_path = os.path.join(kernel_dir, 'include/linux/mmu_notifier.h')

    if not os.path.exists(khuge_path):
        print("[THP-FIX] khugepaged.c not found, skipping mmu_notifier fix")
        return True

    content = read_file(khuge_path)

    # Check if old 3-arg calls exist
    has_old_start = re.search(
        r'mmu_notifier_invalidate_range_start\s*\(\s*\w+\s*,\s*\w+\s*,',
        content
    )
    has_old_end = re.search(
        r'mmu_notifier_invalidate_range_end\s*\(\s*\w+\s*,\s*\w+\s*,',
        content
    )

    if not has_old_start and not has_old_end:
        print("[THP-FIX] No old 3-arg mmu_notifier calls found (already fixed?)")
        return True

    # Check if mmu_notifier_range_init exists in the header
    has_range_init = False
    init_param_order = None

    if os.path.exists(notifier_path):
        notifier_content = read_file(notifier_path)
        if 'mmu_notifier_range_init' in notifier_content:
            has_range_init = True
            print("[THP-FIX] mmu_notifier_range_init found in mmu_notifier.h")
        else:
            print("[THP-FIX] mmu_notifier_range_init NOT found, will use direct struct init")

    # Build replacement for invalidate_range_start
    if has_range_init:
        # Use mmu_notifier_range_init — try different parameter orders
        # Mainline 4.19: (range, event, flags, mm, start, end)
        # Mainline 5.3+: (range, flags, event, mm, start, end)
        # We'll use a macro-like approach that works with both
        start_replacement = (
            r'({ struct mmu_notifier_range __mnr; '
            r'mmu_notifier_range_init(&__mnr, MMU_NOTIFY_CLEAR, 0, \1, \2, \3); '
            r'mmu_notifier_invalidate_range_start(&__mnr); })'
        )
        end_replacement = (
            r'({ struct mmu_notifier_range __mnr; '
            r'mmu_notifier_range_init(&__mnr, MMU_NOTIFY_CLEAR, 0, \1, \2, \3); '
            r'mmu_notifier_invalidate_range_end(&__mnr); })'
        )
    else:
        # Direct struct field initialization
        start_replacement = (
            r'({ struct mmu_notifier_range __mnr; '
            r'__mnr.mm = \1; __mnr.event = MMU_NOTIFY_CLEAR; '
            r'__mnr.start = \2; __mnr.end = \3; '
            r'mmu_notifier_invalidate_range_start(&__mnr); })'
        )
        end_replacement = (
            r'({ struct mmu_notifier_range __mnr; '
            r'__mnr.mm = \1; __mnr.event = MMU_NOTIFY_CLEAR; '
            r'__mnr.start = \2; __mnr.end = \3; '
            r'mmu_notifier_invalidate_range_end(&__mnr); })'
        )

    # Replace old 3-arg calls with struct-based calls
    # Pattern matches: func(mm, addr, end) possibly across multiple lines
    new_content = content

    # Fix invalidate_range_start
    pattern_start = r'mmu_notifier_invalidate_range_start\s*\(\s*(\w+)\s*,\s*(\w+)\s*,\s*(\w+)\s*\)'
    new_content = re.sub(pattern_start, start_replacement, new_content, flags=re.DOTALL)

    # Fix invalidate_range_end
    pattern_end = r'mmu_notifier_invalidate_range_end\s*\(\s*(\w+)\s*,\s*(\w+)\s*,\s*(\w+)\s*\)'
    new_content = re.sub(pattern_end, end_replacement, new_content, flags=re.DOTALL)

    if new_content != content:
        write_file(khuge_path, new_content)
        print("[THP-FIX] Fixed mmu_notifier calls in khugepaged.c")
        return True
    else:
        print("[THP-FIX] WARNING: mmu_notifier patterns did not match, fix may have failed")
        return False


def fix_mmu_notifier_enum(kernel_dir):
    """Fix mmu_notifier.h: add enum mmu_notifier_event definition if missing.

    The vendor kernel's mmu_notifier.h uses 'enum mmu_notifier_event' in the
    mmu_notifier_range_init() function declaration, but the enum may not be
    defined before that point. This causes:
      error: parameter 2 ('event') has incomplete type
      error: function declaration isn't a prototype [-Werror=strict-prototypes]

    This fix adds the enum definition before the function if it's missing.
    """
    notifier_path = os.path.join(kernel_dir, 'include/linux/mmu_notifier.h')

    if not os.path.exists(notifier_path):
        print("[THP-FIX] mmu_notifier.h not found, skipping enum fix")
        return True

    content = read_file(notifier_path)

    # Check if mmu_notifier_range_init uses enum mmu_notifier_event
    if 'enum mmu_notifier_event' not in content:
        print("[THP-FIX] enum mmu_notifier_event not used in mmu_notifier.h, skipping")
        return True

    # Check if the enum is already defined (not just used in a parameter)
    # Look for "enum mmu_notifier_event {" or a typedef
    if re.search(r'enum\s+mmu_notifier_event\s*\{', content):
        print("[THP-FIX] enum mmu_notifier_event already defined in mmu_notifier.h")
        return True

    # Also check if it's defined as a typedef elsewhere
    # In mainline 4.19, the enum might be defined in a different header
    # Check if MMU_NOTIFY_CLEAR is defined (it's a value of this enum)
    if 'MMU_NOTIFY_CLEAR' not in content:
        # The enum values aren't defined here either — add the full enum
        enum_def = (
            '\nenum mmu_notifier_event {\n'
            '\tMMU_NOTIFY_UNMAP = 0,\n'
            '\tMMU_NOTIFY_CLEAR,\n'
            '\tMMU_NOTIFY_PROTECTION_VMA,\n'
            '\tMMU_NOTIFY_SOFT_DIRTY,\n'
            '\tMMU_MIGRATE,\n'
            '\tMMU_NOTIFY_RELEASE,\n'
            '};\n'
        )

        # Insert before the first use of enum mmu_notifier_event
        # Find the mmu_notifier_range_init function declaration
        match = re.search(r'(static inline void mmu_notifier_range_init)', content)
        if match:
            insert_pos = match.start()
            content = content[:insert_pos] + enum_def + '\n' + content[insert_pos:]
            write_file(notifier_path, content)
            print("[THP-FIX] Added enum mmu_notifier_event definition to mmu_notifier.h")
            return True
        else:
            # Insert at a reasonable position — after the includes/guards
            # Find the struct mmu_notifier_range definition
            match = re.search(r'(struct mmu_notifier_range)', content)
            if match:
                insert_pos = match.start()
                content = content[:insert_pos] + enum_def + '\n' + content[insert_pos:]
                write_file(notifier_path, content)
                print("[THP-FIX] Added enum mmu_notifier_event definition to mmu_notifier.h (before struct)")
                return True
            else:
                print("[THP-FIX] WARNING: Could not find insertion point for enum in mmu_notifier.h")
                return False
    else:
        # MMU_NOTIFY_CLEAR is defined but enum isn't — might be #define
        print("[THP-FIX] MMU_NOTIFY_CLEAR found but enum not defined — may use #define, skipping")
        return True


def fix_maybe_mkwrite(kernel_dir):
    """Fix maybe_mkwrite() calls to use vma->vm_flags instead of vma."""
    for filename in ['mm/huge_memory.c', 'mm/khugepaged.c', 'mm/memory.c']:
        path = os.path.join(kernel_dir, filename)
        if not os.path.exists(path):
            continue

        content = read_file(path)

        # Replace maybe_mkwrite(xxx, vma) with maybe_mkwrite(xxx, vma->vm_flags)
        # But don't replace if it already uses vm_flags
        old_pattern = r'maybe_mkwrite\s*\(([^,]+),\s*vma\s*\)'
        if re.search(old_pattern, content):
            new_content = re.sub(
                old_pattern,
                r'maybe_mkwrite(\1, vma->vm_flags)',
                content
            )
            if new_content != content:
                write_file(path, new_content)
                print(f"[THP-FIX] Fixed maybe_mkwrite in {filename}")
        else:
            # Maybe already fixed or pattern differs
            pass

    return True


def verify_fixes(kernel_dir):
    """Verify that the old patterns no longer exist."""
    issues = []

    huge_path = os.path.join(kernel_dir, 'mm/huge_memory.c')
    if os.path.exists(huge_path):
        content = read_file(huge_path)
        # Check for 2-arg try_to_unmap (without the 3rd arg we added)
        if re.search(r'try_to_unmap\s*\(\s*page\s*,\s*ttu_flags\s*\)', content):
            # Make sure it's NOT followed by a comma (which would mean 3-arg)
            if not re.search(r'try_to_unmap\s*\(\s*page\s*,\s*ttu_flags\s*,', content):
                issues.append("huge_memory.c still has 2-arg try_to_unmap call")

    khuge_path = os.path.join(kernel_dir, 'mm/khugepaged.c')
    if os.path.exists(khuge_path):
        content = read_file(khuge_path)
        if re.search(r'mmu_notifier_invalidate_range_start\s*\(\s*\w+\s*,\s*\w+\s*,', content):
            issues.append("khugepaged.c still has old 3-arg mmu_notifier_invalidate_range_start")
        if re.search(r'mmu_notifier_invalidate_range_end\s*\(\s*\w+\s*,\s*\w+\s*,', content):
            issues.append("khugepaged.c still has old 3-arg mmu_notifier_invalidate_range_end")

    if issues:
        print("[THP-FIX] VERIFICATION FAILED:")
        for issue in issues:
            print(f"  - {issue}")
        return False
    else:
        print("[THP-FIX] Verification passed: all old patterns have been replaced")
        return True


def main():
    kernel_dir = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()

    print(f"[THP-FIX] Kernel dir: {kernel_dir}")
    print(f"[THP-FIX] Fixing THP API compatibility issues...")

    # Verify kernel source
    if not os.path.exists(os.path.join(kernel_dir, 'Makefile')):
        print("[THP-FIX] ERROR: Not a kernel source directory")
        sys.exit(1)

    success = True

    # Fix 1: try_to_unmap in huge_memory.c
    try:
        if not fix_try_to_unmap(kernel_dir):
            success = False
    except Exception as e:
        print(f"[THP-FIX] ERROR fixing try_to_unmap: {e}")
        success = False

    # Fix 2: mmu_notifier in khugepaged.c
    try:
        if not fix_mmu_notifier(kernel_dir):
            success = False
    except Exception as e:
        print(f"[THP-FIX] ERROR fixing mmu_notifier: {e}")
        success = False

    # Fix 2b: mmu_notifier.h enum definition (causes prepare0 build failure)
    try:
        if not fix_mmu_notifier_enum(kernel_dir):
            success = False
    except Exception as e:
        print(f"[THP-FIX] ERROR fixing mmu_notifier enum: {e}")
        success = False

    # Fix 3: maybe_mkwrite in multiple files
    try:
        fix_maybe_mkwrite(kernel_dir)
    except Exception as e:
        print(f"[THP-FIX] WARNING fixing maybe_mkwrite: {e}")
        # This is just a warning, not a hard failure

    # Verify all fixes
    if success:
        success = verify_fixes(kernel_dir)

    if success:
        print("[THP-FIX] All THP fixes applied successfully!")
        sys.exit(0)
    else:
        print("[THP-FIX] Some fixes failed! THP should be disabled as fallback.")
        sys.exit(1)


if __name__ == '__main__':
    main()
