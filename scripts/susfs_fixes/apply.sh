#!/usr/bin/env bash
# 应用 SUSFS 补丁及各内核版本所需的上下文修复
# 依赖环境变量：
#   ANDROID_VERSION KERNEL_VERSION KSU_VARIANT OS_PATCH_LEVEL SUB_LEVEL
#   KERNEL_ROOT SUSFS4KSU KERNEL_PATCHES LEGACY_SUKISU_CONFIG
# 调用前必须将工作目录设为 $KERNEL_ROOT
set -eo pipefail

# 列出当前目录下不属于上游的 .rej（相对路径，已排序）。
# 上游分支可能自带已提交的 .rej（如 android15-6.6-2026-04 的 mm/rmap.c.rej，
# 是上游解决合并冲突时的残留），那不是本补丁的冲突；但 patch 失败时会覆盖同名文件，
# 所以只有「被 git 跟踪且未改动」的才视为上游自带。
# 不在 git 仓库里（本地 verify_context.sh）时 git 命令为空，退回全部 .rej
list_upstream_rej() {
  git ls-files -- '*.rej' 2>/dev/null | while IFS= read -r f; do
    git diff --quiet -- "$f" 2>/dev/null && echo "$f"
  done
}
list_untracked_rej() {
  comm -23 \
    <(find . -type f -name '*.rej' | sed 's|^\./||' | sort) \
    <(list_upstream_rej | sort)
}

echo "应用 SUSFS 补丁..."

SUSFS_PATCH="50_add_susfs_in_gki-$ANDROID_VERSION-$KERNEL_VERSION.patch"
cp "$SUSFS4KSU/kernel_patches/$SUSFS_PATCH" ./common/
cp "$SUSFS4KSU"/kernel_patches/fs/* ./common/fs/
cp "$SUSFS4KSU"/kernel_patches/include/linux/* ./common/include/linux/

case "$KSU_VARIANT" in
  "Official"|"FolkSU")
    cd ./KernelSU
    cp "$SUSFS4KSU"/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch ./
    patch -p1 --forward < 10_enable_susfs_for_ksu.patch || true

    cd ..
    ;;
  "Next"|"SukiSU"|"SukiSU(40726)"|"SukiSU(40548)"|"BakaSU")
    echo "Next/SukiSU/SukiSU(40726)/SukiSU(40548)/BakaSU 使用内置 SUSFS 支持"
    ;;
esac

# FolkSU: 10_enable_susfs_for_ksu.patch 与 FolkSU 的分支代码存在上下文差异，
# 部分 hunk 未应用（init.c / selinux_hide.c 等），这里按补丁意图完成缺失的适配：
#   0) selinux_hide.c 回退为原始版本（混合状态会在 LTO 链接时产生符号问题），
#      并恢复其依赖的基础模块（symbol_resolver / patch_memory / lsm_hook）
#   1) 移除指向已移出编译列表模块的调用
#   2) 恢复补丁删除、但 FolkSU 其余代码仍在使用的全局变量
#   3) 移除已被补丁整体删除的 ksu_app_profile_init 调用
#   4) 补齐头文件声明、SUSFS 初始化与新架构初始化调用
if [ "$KSU_VARIANT" == "FolkSU" ]; then
  FOLKSU_KSU="$KERNEL_ROOT/KernelSU/kernel"
  FOLKSU_INIT="$FOLKSU_KSU/core/init.c"
  FOLKSU_KSU_H="$FOLKSU_KSU/include/ksu.h"
  if [ ! -f "$FOLKSU_INIT" ] || [ ! -f "$FOLKSU_KSU_H" ]; then
    echo "::error::未找到 FolkSU 内核源码文件 (core/init.c / include/ksu.h)" >&2
    exit 1
  fi

  # 0) 回退 selinux_hide.c，并恢复其依赖的基础模块进入编译列表
  if git -C "$KERNEL_ROOT/KernelSU" rev-parse --git-dir > /dev/null 2>&1; then
    git -C "$KERNEL_ROOT/KernelSU" checkout -- kernel/feature/selinux_hide.c
  fi
  if ! grep -q 'hook/lsm_hook.o' "$FOLKSU_KSU/Kbuild"; then
    sed -i 's|^kernelsu-objs += hook/setuid_hook.o$|kernelsu-objs += hook/setuid_hook.o\nkernelsu-objs += hook/lsm_hook.o\nkernelsu-objs += infra/symbol_resolver.o\n\nifeq ($(CONFIG_ARM64),y)\nkernelsu-objs += hook/arm64/patch_memory.o\nelse ifeq ($(CONFIG_X86_64),y)\nkernelsu-objs += hook/x86_64/patch_memory.o\nelse ifeq ($(CONFIG_RISCV),y)\nkernelsu-objs += hook/riscv64/patch_memory.o\nendif|' "$FOLKSU_KSU/Kbuild"
  fi

  # 1) 移除已不参与编译的模块的调用（仅剩 syscall hook / syscall hook manager）
  sed -i \
    -e '/^[[:space:]]*ksu_syscall_hook_init();$/d' \
    -e '/^[[:space:]]*ksu_syscall_hook_manager_init();$/d' \
    -e '/^[[:space:]]*ksu_syscall_hook_manager_exit();$/d' \
    "$FOLKSU_INIT"

  # 1b) 补回 lsm hook 退出调用（补丁删除了它，而该模块已恢复）
  if ! grep -q 'ksu_lsm_hook_exit();' "$FOLKSU_INIT"; then
    sed -i 's|^[[:space:]]*ksu_selinux_hide_exit();$|    ksu_lsm_hook_exit();\n    ksu_selinux_hide_exit();|' "$FOLKSU_INIT"
  fi

  # 3) ksu_app_profile_init 已被补丁从 app_profile.c/h 整体删除，去掉残留调用
  if ! grep -q 'void __init ksu_app_profile_init(' "$FOLKSU_KSU/policy/app_profile.c"; then
    sed -i '/^[[:space:]]*ksu_app_profile_init();$/d' "$FOLKSU_INIT"
  fi

  # 2) 恢复 ksu_late_loaded / ksu_bundled（补丁从 ksu.h 与 init.c 删除，
  #    但 FolkSU 的 dispatch / selinux_hide / ksud_integration 仍在使用）
  if ! grep -q 'extern bool ksu_late_loaded;' "$FOLKSU_KSU_H"; then
    sed -i 's|^extern bool ksu_no_custom_rc;$|extern bool ksu_no_custom_rc;\nextern bool ksu_late_loaded;\nextern bool ksu_bundled;|' "$FOLKSU_KSU_H"
  fi
  if ! grep -q '^bool ksu_late_loaded;' "$FOLKSU_INIT"; then
    sed -i 's|^struct cred \*ksu_cred;$|struct cred *ksu_cred;\n\nbool ksu_late_loaded;\n\n#ifdef MODULE\nbool ksu_bundled = false;\nmodule_param_named(bundled, ksu_bundled, bool, 0);\n#endif|' "$FOLKSU_INIT"
  fi

  # 4a) 补齐新架构初始化函数的头文件声明
  if ! grep -q '#include "feature/sucompat.h"' "$FOLKSU_INIT"; then
    sed -i 's|^#include "feature/avc_spoof.h"$|#include "feature/avc_spoof.h"\n#include "feature/sucompat.h"\n#include "hook/setuid_hook.h"|' "$FOLKSU_INIT"
  fi

  # 4a2) 补回 lsm_hook 头文件（补丁删除了该 include，而调用已恢复）
  if ! grep -q '#include "hook/lsm_hook.h"' "$FOLKSU_INIT"; then
    sed -i 's|^#include "hook/setuid_hook.h"$|#include "hook/setuid_hook.h"\n#include "hook/lsm_hook.h"|' "$FOLKSU_INIT"
  fi

  # 4b) SUSFS 初始化（补丁已在 init.c 顶部加入 susfs.h 头文件）
  if ! grep -q 'susfs_init();' "$FOLKSU_INIT"; then
    sed -i 's|^[[:space:]]*ksu_feature_init();$|#ifdef CONFIG_KSU_SUSFS\n    susfs_init();\n#endif // #ifdef CONFIG_KSU_SUSFS\n    ksu_feature_init();|' "$FOLKSU_INIT"
  fi

  # 4c) 原先由 hook/syscall_hook_manager.c 代调用的初始化，改为 init.c 直接调用
  if ! grep -q 'ksu_sucompat_init();' "$FOLKSU_INIT"; then
    sed -i 's|^[[:space:]]*ksu_supercalls_init();$|    ksu_supercalls_init();\n\n    ksu_sucompat_init();\n\n    ksu_setuid_hook_init();|' "$FOLKSU_INIT"
  fi

  # 5) 部分应用的补丁会残留少量 unused 代码（如 selinux_hide.c），
  #    GKI 的 -Werror 下放行该告警类别，避免遗留代码阻断编译
  if ! grep -q 'Wno-error=unused-variable' "$FOLKSU_KSU/Kbuild"; then
    cat >> "$FOLKSU_KSU/Kbuild" << 'KSU_KBUILD_EOF'

# FolkSU: SUSFS 补丁部分应用后的残留代码允许 unused 类告警
ccflags-y += -Wno-error=unused-variable -Wno-error=unused-function -Wno-error=unused-but-set-variable -Wno-error=unused-const-variable
KSU_KBUILD_EOF
  fi

  # 结果校验，防止上游代码结构变化后静默失效
  if ! grep -q 'susfs_init();' "$FOLKSU_INIT" \
    || ! grep -q 'ksu_sucompat_init();' "$FOLKSU_INIT" \
    || ! grep -q 'ksu_setuid_hook_init();' "$FOLKSU_INIT" \
    || ! grep -q 'ksu_init_symbol_resolver();' "$FOLKSU_INIT" \
    || ! grep -q 'ksu_lsm_hook_init();' "$FOLKSU_INIT" \
    || ! grep -q 'ksu_lsm_hook_exit();' "$FOLKSU_INIT" \
    || ! grep -q '#include "hook/lsm_hook.h"' "$FOLKSU_INIT" \
    || ! grep -q '^bool ksu_late_loaded;' "$FOLKSU_INIT" \
    || ! grep -q 'extern bool ksu_late_loaded;' "$FOLKSU_KSU_H" \
    || ! grep -q 'hook/lsm_hook.o' "$FOLKSU_KSU/Kbuild" \
    || ! grep -q 'infra/symbol_resolver.o' "$FOLKSU_KSU/Kbuild"; then
    echo "::error::FolkSU 适配修复失败，代码结构可能已变化" >&2
    exit 1
  fi
  if grep -qE 'ksu_syscall_hook_init\(\)|ksu_syscall_hook_manager_(init|exit)\(\)' "$FOLKSU_INIT"; then
    echo "::error::FolkSU init.c 仍存在指向已移除模块的调用" >&2
    exit 1
  fi
  if git -C "$KERNEL_ROOT/KernelSU" rev-parse --git-dir > /dev/null 2>&1 \
    && ! git -C "$KERNEL_ROOT/KernelSU" diff --quiet -- kernel/feature/selinux_hide.c; then
    echo "::error::FolkSU selinux_hide.c 未能回退为原始版本" >&2
    exit 1
  fi
fi

cd "$KERNEL_ROOT/common"
CURRENT_SUB="$SUB_LEVEL"
if [[ ! "$CURRENT_SUB" =~ ^[0-9]+$ ]]; then
  CURRENT_SUB=99999
fi

# 兼容缺少 VMA padding 接口的 5.10.66～209、5.15.74～144 和 6.1.25～68
if grep -qF 'VMA_PAD_START(vma)' "$SUSFS_PATCH" \
  && ! grep -Rqs 'VMA_PAD_START' ./include/linux; then
  echo "目标内核未提供 VMA_PAD_START，使用 vma->vm_end 兼容 SUSFS OPEN_REDIRECT"
  sed -i 's/VMA_PAD_START(vma)/vma->vm_end/g' "$SUSFS_PATCH"
fi

adjust_legacy_fdinfo_context() {
  sed -i '/^[[:space:]]*\/\*$/,/^[[:space:]]*u32 mask = mark->mask & IN_ALL_EVENTS;$/d' fs/notify/fdinfo.c
  perl -i -pe 's/\bmask,\s*mark->ignored_mask/inotify_mark_user_mask(mark)/g' fs/notify/fdinfo.c
  perl -i -pe 's/ignored_mask:%x/ignored_mask:0/g' fs/notify/fdinfo.c
}

restore_legacy_fdinfo_context() {
  perl -i -pe 's/^(\s+if \(inode\) \{)/$1\n\t\t\/\*\n\t\t * IN_ALL_EVENTS represents all of the mask bits\n\t\t * that we expose to userspace.  There is at\n\t\t * least one bit (FS_EVENT_ON_CHILD) which is\n\t\t * used only internally to the kernel.\n\t\t *\/\n\t\tu32 mask = mark->mask & IN_ALL_EVENTS;/m' fs/notify/fdinfo.c
  perl -i -pe 's/\binotify_mark_user_mask\(mark\)/mask, mark->ignored_mask/g' fs/notify/fdinfo.c
  perl -i -pe 's/ignored_mask:0/ignored_mask:%x/g' fs/notify/fdinfo.c
}

# 临时调整旧内核源码上下文，使 SUSFS 主补丁可以匹配
if [[ "$ANDROID_VERSION" == "android12" && "$KERNEL_VERSION" == "5.10" ]]; then
  if [[ -n "$LEGACY_SUKISU_CONFIG" && "$CURRENT_SUB" -le 43 ]]; then
    echo "临时调整 Android 12 5.10 base.c 上下文"
    perl -i -pe 's/(int|size_t)\s+this_len\s*=\s*min_t\s*\(\s*\1\s*,/size_t this_len = min_t(size_t,/;' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 117 ]]; then
    echo "临时调整 Android 12 5.10 fdinfo.c 上下文"
    adjust_legacy_fdinfo_context
  fi
fi

if [[ "$ANDROID_VERSION" == "android13" && "$KERNEL_VERSION" == "5.15" ]]; then
  if [[ "$CURRENT_SUB" -le 41 ]]; then
    echo "临时调整 Android 13 5.15 namespace.c/open.c/fdinfo.c 上下文"
    if ! grep -qF '#include <linux/mnt_idmapping.h>' fs/namespace.c; then
      sed -i '/^#include <linux\/shmem_fs.h>$/a #include <linux/mnt_idmapping.h>' fs/namespace.c
    fi
    if ! grep -qF '#include <linux/mnt_idmapping.h>' fs/open.c; then
      sed -i '/^#include <linux\/compat.h>$/a #include <linux/mnt_idmapping.h>' fs/open.c
    fi
    adjust_legacy_fdinfo_context
  fi
  if [[ "$OS_PATCH_LEVEL" == "lts" ]]; then
    echo "临时调整 Android 13 5.15 LTS 头文件上下文"
    sed -i '/^#include <trace\/hooks\/blk.h>$/d' fs/namespace.c
    sed -i '/^#include <trace\/hooks\/mm.h>$/d' fs/proc/task_mmu.c
  fi
fi

if [[ "$ANDROID_VERSION" == "android14" && "$KERNEL_VERSION" == "6.1" ]]; then
  if [[ "$CURRENT_SUB" -le 25 ]] && ! grep -qF '#include <trace/hooks/sched.h>' fs/proc/base.c; then
    echo "临时调整 Android 14 6.1 sched.h 上下文"
    sed -i '/^#include <trace\/events\/oom.h>$/a #include <trace/hooks/sched.h>' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 141 ]] && ! grep -qF '#include <linux/dma-buf.h>' fs/proc/base.c; then
    echo "临时调整 Android 14 6.1 dma-buf.h 上下文"
    sed -i '/^#include <linux\/cpufreq_times.h>$/a #include <linux/dma-buf.h>' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -ge 157 ]]; then
    echo "临时调整 Android 14 6.1 namespace.c 上下文"
    sed -i '/^#include <trace\/hooks\/blk.h>$/d' fs/namespace.c
  fi
fi

if [[ "$ANDROID_VERSION" == "android15" && "$KERNEL_VERSION" == "6.6" ]]; then
  if [[ "$CURRENT_SUB" -le 92 ]] && ! grep -qF '#include <linux/dma-buf.h>' fs/proc/base.c; then
    echo "临时调整 Android 15 6.6 base.c 上下文"
    sed -i '/^#include <linux\/cpufreq_times.h>$/a #include <linux/dma-buf.h>' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 57 ]] && ! grep -qF '#include <linux/zswap.h>' mm/memory.c; then
    echo "临时调整 Android 15 6.6 memory.c 上下文"
    sed -i '/^#include <linux\/sched\/sysctl.h>$/a #include <linux/zswap.h>' mm/memory.c
  fi
fi

if [[ "$ANDROID_VERSION" == "android16" && "$KERNEL_VERSION" == "6.12" ]]; then
  if [[ "$CURRENT_SUB" -ge 58 ]]; then
    echo "临时调整 Android 16 6.12 exec.c 上下文"
    sed -i '/^#include <linux\/dma-buf.h>$/d' fs/exec.c
  fi
fi

# 新版内核在 super.c 的 internal.h 之后新增了 trace/hooks/fs.h，
# 旧版 SUSFS 主补丁以 thaw_super_locked 为上下文插入 extern 声明，会整段被拒绝；
# 上游 2026-09-15 起已把声明挪到 unnamed_dev_ida 之后，不再依赖这段上下文，
# 但 ShirkNeko fork 尚未同步（固定提交的旧版补丁不改 super.c），只对旧版补丁做临时调整
SUPER_FS_H_REMOVED=""
if grep -q '^ static int thaw_super_locked' "$SUSFS_PATCH" \
  && grep -qF '#include <trace/hooks/fs.h>' fs/super.c; then
  echo "临时调整 super.c 上下文"
  sed -i '/^#include <trace\/hooks\/fs.h>$/,+1d' fs/super.c
  SUPER_FS_H_REMOVED=1
fi

patch -p1 < "$SUSFS_PATCH" || true

# 为尚未提供 SU 会话 FD 接口的 SukiSU/BakaSU 恢复旧版 exec hook 行为
EXEC_HELPER=""
if [[ "$KSU_VARIANT" == SukiSU* || "$KSU_VARIANT" == "BakaSU" ]]; then
  if grep -qF 'ksu_install_su_fd();' fs/exec.c; then
    EXEC_HELPER="ksu_install_su_fd"
  elif grep -qF 'ksu_handle_post_execveat_sucompat(' fs/exec.c; then
    EXEC_HELPER="ksu_handle_post_execveat_sucompat"
  fi
fi
if [[ -n "$EXEC_HELPER" ]] \
  && ! grep -RqsE --include='*.c' "^[[:space:]]*int[[:space:]]+${EXEC_HELPER}[[:space:]]*\(" "$KERNEL_ROOT/KernelSU/kernel"; then
  echo "$KSU_VARIANT 尚未提供 $EXEC_HELPER，恢复旧版 exec hook"
  sed -i '/^extern int ksu_install_su_fd(void);$/d' fs/exec.c
  sed -i '/^extern int ksu_handle_post_execveat_sucompat(/,+1d' fs/exec.c
  sed -i 's/is_su_session = !\(ksu_handle_execveat[^;]*;\)/\1/' fs/exec.c
  sed -i '/^[[:space:]]*bool is_su_session = false;$/d' fs/exec.c
  sed -i '/^[[:space:]]*if (unlikely(is_su_session && retval >= 0))$/,+1d' fs/exec.c
  sed -i '/^[[:space:]]*if (unlikely(is_su_session))$/,+1d' fs/exec.c
  sed -i '/^#ifdef CONFIG_KSU_SUSFS$/N;/^#ifdef CONFIG_KSU_SUSFS\n#endif \/\/ #ifdef CONFIG_KSU_SUSFS$/d' fs/exec.c
  if grep -qE 'ksu_install_su_fd|ksu_handle_post_execveat_sucompat|is_su_session' fs/exec.c; then
    echo "::error::$KSU_VARIANT exec hook 结构已变化，无法完成兼容修复"
    exit 1
  fi
fi

# 上游 5.10 补丁把 susfs_sus_kstat_spoof_vfs_statfs 的 extern 声明放在了
# susfs_statfs_by_dentry 之后，clang -Werror 会报隐式声明；声明晚于使用时前移
if [[ -f fs/statfs.c ]] && grep -qF 'susfs_sus_kstat_spoof_vfs_statfs(' fs/statfs.c; then
  STATFS_USE=$(grep -n 'if (!susfs_sus_kstat_spoof_vfs_statfs(' fs/statfs.c | head -1 | cut -d: -f1)
  STATFS_DECL=$(grep -n '^extern int susfs_sus_kstat_spoof_vfs_statfs(' fs/statfs.c | head -1 | cut -d: -f1)
  if [[ -n "$STATFS_USE" && -n "$STATFS_DECL" && "$STATFS_DECL" -gt "$STATFS_USE" ]] \
    && grep -q '^static int susfs_statfs_by_dentry(' fs/statfs.c; then
    echo "前移 statfs.c 中 susfs_sus_kstat_spoof_vfs_statfs 的声明"
    sed -i '/^static int susfs_statfs_by_dentry(/i extern int susfs_sus_kstat_spoof_vfs_statfs(struct inode *inode, struct kstatfs *buf, bool *is_fuse);' fs/statfs.c
  fi
fi

# 在编译前报告 SUSFS 主补丁产生的冲突文件，上游自带的 .rej 不计入
mapfile -t SUSFS_REJ_FILES < <(list_untracked_rej)
SUSFS_REJ_COUNT=${#SUSFS_REJ_FILES[@]}
if [ "$SUSFS_REJ_COUNT" -gt 0 ]; then
  echo "::warning title=SUSFS 补丁冲突::SUSFS 主补丁产生了 ${SUSFS_REJ_COUNT} 个 .rej 冲突文件，可能导致后续编译失败（详见 Rejects 产物）"
  printf '%s\n' "${SUSFS_REJ_FILES[@]}"
fi

# 还原仅用于补丁匹配的临时源码调整
if [[ "$ANDROID_VERSION" == "android12" && "$KERNEL_VERSION" == "5.10" ]]; then
  if [[ -n "$LEGACY_SUKISU_CONFIG" && "$CURRENT_SUB" -le 43 ]]; then
    echo "还原 Android 12 5.10 base.c 临时调整"
    sed -i 's/^size_t this_len = min_t(size_t, count, PAGE_SIZE);$/int this_len = min_t(int, count, PAGE_SIZE);/' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 117 ]]; then
    echo "还原 Android 12 5.10 fdinfo.c 临时调整"
    restore_legacy_fdinfo_context
  fi
fi

if [[ "$ANDROID_VERSION" == "android13" && "$KERNEL_VERSION" == "5.15" ]]; then
  if [[ "$CURRENT_SUB" -le 41 ]]; then
    echo "还原 Android 13 5.15 临时调整"
    sed -i '/#include <linux\/mnt_idmapping.h>$/d' fs/namespace.c
    sed -i '/#include <linux\/mnt_idmapping.h>$/d' fs/open.c
    restore_legacy_fdinfo_context
    sed -i 's|i_uid_into_mnt(i_user_ns(&fi->inode), &fi->inode).val|i_uid_into_mnt(\&init_user_ns, \&fi->inode).val|g' fs/susfs.c
    sed -i 's|i_uid_into_mnt(i_user_ns(inode), inode).val|i_uid_into_mnt(\&init_user_ns, inode).val|g' fs/susfs.c
  fi
  if [[ "$OS_PATCH_LEVEL" == "lts" ]]; then
    echo "还原 Android 13 5.15 LTS 头文件上下文"
    if ! grep -qF '#include <trace/hooks/blk.h>' fs/namespace.c; then
      sed -i '/^#include "internal.h"$/a #include <trace/hooks/blk.h>' fs/namespace.c
    fi
    if ! grep -qF '#include <trace/hooks/mm.h>' fs/proc/task_mmu.c; then
      sed -i '/^#include <linux\/pkeys.h>$/a #include <trace/hooks/mm.h>' fs/proc/task_mmu.c
    fi
  fi
fi

if [[ "$ANDROID_VERSION" == "android14" && "$KERNEL_VERSION" == "6.1" ]]; then
  if [[ "$CURRENT_SUB" -le 25 ]]; then
    sed -i '/^#include <trace\/hooks\/sched.h>$/d' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 141 ]]; then
    echo "还原 Android 14 6.1 base.c 临时调整"
    sed -i '/^#include <linux\/dma-buf.h>$/d' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -ge 157 ]] && ! grep -qF '#include <trace/hooks/blk.h>' fs/namespace.c; then
    echo "还原 Android 14 6.1 namespace.c 临时调整"
    sed -i '/^#include "internal.h"$/a #include <trace/hooks/blk.h>' fs/namespace.c
  fi
fi

if [[ "$ANDROID_VERSION" == "android15" && "$KERNEL_VERSION" == "6.6" ]]; then
  if [[ "$CURRENT_SUB" -le 92 ]]; then
    echo "还原 Android 15 6.6 base.c 临时调整"
    sed -i '/^#include <linux\/dma-buf.h>$/d' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 57 ]]; then
    echo "还原 Android 15 6.6 memory.c 临时调整"
    sed -i '/^#include <linux\/zswap.h>$/d' mm/memory.c
  fi
fi

if [[ "$ANDROID_VERSION" == "android16" && "$KERNEL_VERSION" == "6.12" ]]; then
  if [[ "$CURRENT_SUB" -ge 58 ]] && ! grep -qF '#include <linux/dma-buf.h>' fs/exec.c; then
    echo "还原 Android 16 6.12 exec.c 临时调整"
    sed -i '0,/^#include /s//#include <linux\/dma-buf.h>\n&/' fs/exec.c
  fi
fi

if [[ -n "$SUPER_FS_H_REMOVED" ]] \
  && ! grep -qF '#include <trace/hooks/fs.h>' fs/super.c; then
  echo "还原 super.c 临时调整"
  sed -i '/^#include "internal.h"$/a #include <trace/hooks/fs.h>' fs/super.c
fi

fix_missing_vm_flags_clear() {
  if [[ "$OS_PATCH_LEVEL" == "2024-11" ]] && grep -qF 'vm_flags_clear(new_vma, VM_PAD_MASK);' ./mm/mmap.c; then
    sed -i 's/vm_flags_clear(new_vma, VM_PAD_MASK);/new_vma->vm_flags \&= ~VM_PAD_MASK;/' ./mm/mmap.c
  fi
}

fix_task_mmu_show_pad() {
  local max_sub="$1"
  local excluded_patch_level="${2:-}"

  # 仅固定旧版 SUSFS 补丁会引入 goto show_pad，最新版已不再包含该代码
  if [[ -n "$LEGACY_SUKISU_CONFIG" && "$CURRENT_SUB" -le "$max_sub" ]] \
    && { [[ -z "$excluded_patch_level" ]] || [[ "$OS_PATCH_LEVEL" != "$excluded_patch_level" ]]; }; then
    sed -i -e 's/goto show_pad;/return 0;/' ./fs/proc/task_mmu.c
  fi
}

# Android 12 - 5.10 修复
if [[ "$ANDROID_VERSION" == "android12" && "$KERNEL_VERSION" == "5.10" ]]; then
  # 修复 2024-11 分支: mmap.c 调用了 vm_flags_clear()，但同分支 mm.h 未提供 helper
  fix_missing_vm_flags_clear
  fix_task_mmu_show_pad 209
fi

# Android 13 - 5.15 修复
  if [[ "$ANDROID_VERSION" == "android13" && "$KERNEL_VERSION" == "5.15" ]]; then
  # 修复 2024-11 分支: mmap.c 调用了 vm_flags_clear()，但同分支 mm.h 未提供 helper
  fix_missing_vm_flags_clear
  fix_task_mmu_show_pad 148 "2024-05"
fi

# Android 14 - 6.1 修复
if [[ "$ANDROID_VERSION" == "android14" && "$KERNEL_VERSION" == "6.1" ]]; then
  fix_task_mmu_show_pad 75 "2024-05"
fi

# Android 15 - 6.6 修复
if [[ "$ANDROID_VERSION" == "android15" && "$KERNEL_VERSION" == "6.6" ]]; then
  # 修复老版 SukiSU 6.6.50~6.6.58: task_mmu.c 打入 SUSFS 后使用 vma，但旧源码没有对应声明
  if [[ -n "$LEGACY_SUKISU_CONFIG" && "$CURRENT_SUB" -ge 50 && "$CURRENT_SUB" -le 58 ]] \
    && grep -qF 'vma = find_vma(mm, start_vaddr);' ./fs/proc/task_mmu.c; then
    TASK_MMU_PATCH="$KERNEL_PATCHES/wild/archived/susfs_fix_patches/v2.1.0/a15-6.6/task_mmu.c.patch"
    if [ ! -f "$TASK_MMU_PATCH" ]; then
      echo "::error::补丁不存在: $TASK_MMU_PATCH"
      exit 1
    fi
    cp "$TASK_MMU_PATCH" ./
    if patch -p1 --dry-run < task_mmu.c.patch >/dev/null 2>&1; then
      patch -p1 --no-backup-if-mismatch < task_mmu.c.patch
      echo "已应用 Android 15 6.6.50~6.6.58 task_mmu.c 归档修复补丁"
    else
      echo "Android 15 6.6.50~6.6.58 task_mmu.c 归档修复补丁已应用或当前上下文不匹配，跳过"
    fi
  fi
fi

# Android 16 - 6.12 修复
if [[ "$ANDROID_VERSION" == "android16" && "$KERNEL_VERSION" == "6.12" ]]; then
  # 固定旧版 SukiSU 在 6.12 上会重复定义 setresuid hook
  SETUID_HOOK="$KERNEL_ROOT/common/drivers/kernelsu/setuid_hook.c"
  if [[ -n "$LEGACY_SUKISU_CONFIG" && -f "$SETUID_HOOK" ]] \
    && grep -qF 'defined(CONFIG_KSU_MANUAL_HOOK))' "$SETUID_HOOK"; then
    sed -i 's/defined(CONFIG_KSU_MANUAL_HOOK))/!defined(CONFIG_KSU_SUSFS) \&\& defined(CONFIG_KSU_MANUAL_HOOK))/' "$SETUID_HOOK"
    echo "已修复 setuid_hook.c 重复定义问题"
  fi
fi
