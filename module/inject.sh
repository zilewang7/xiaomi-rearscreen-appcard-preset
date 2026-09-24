#!/system/bin/sh
# ============================================================================
# RearScreen AppCard Preset — 注入脚本
#
# 作用：把模块自带的预置应用卡注入到系统路径
#       /system/media/rearscreen/appcard/  （真实路径 /product/media/rearscreen，
#       因为 /system/media 是指向 /product/media 的软链）
#
# 为什么用脚本而不是模块文件挂载：
#   新版 APatch 把「模块文件挂载」委托给 metamodule（/data/adb/metamodule），
#   未安装 metamodule 时不会挂载任何模块文件；
#   但 apd 仍会在 post-fs-data / service / boot-completed 三个阶段执行
#   各模块目录下同名的 .sh 脚本（apd/src/module.rs::exec_stage_script）。
#   因此这里自己完成 bind mount —— 与 reqable-magisk 处理 Android 14+
#   cacerts 的做法是同一模式。
#
# 本脚本是幂等的，三个阶段共用同一份。
# ============================================================================

MODDIR=${0%/*}
[ -d "$MODDIR/product/media/rearscreen" ] || MODDIR=/data/adb/modules/reareye_appcard_preset

SRC="$MODDIR/product/media/rearscreen"
DST=/system/media/rearscreen
MARK="$DST/appcard/default/rearScreen.json"
LOG=/data/local/tmp/reareye_appcard_preset.log

log() { echo "[$(date '+%F %T')] $*" >> "$LOG" 2>/dev/null; }

log "stage=${0##*/} start uid=$(id -u)"

# 1) 已生效则退出（脚本已跑过，或将来装了 metamodule 由它挂载）
if [ -e "$MARK" ]; then
    log "already present, skip"
    exit 0
fi

# 2) 等待目标分区与源目录就绪
i=0
while [ "$i" -lt 120 ]; do
    [ -d "$DST" ] && [ -d "$SRC" ] && break
    sleep 1
    i=$((i + 1))
done
if [ ! -d "$DST" ] || [ ! -d "$SRC" ]; then
    log "path not ready: DST=$([ -d "$DST" ] && echo ok || echo miss) SRC=$([ -d "$SRC" ] && echo ok || echo miss)"
    exit 1
fi

# 3) 修正 SELinux 上下文，否则 untrusted_app 无法读取
chcon -R u:object_r:system_file:s0 "$SRC" 2>>"$LOG"

# 4) bind mount
mount --bind "$SRC" "$DST" 2>>"$LOG"
rc=$?

if [ -e "$MARK" ]; then
    log "MOUNT OK (rc=$rc)"
    exit 0
fi

log "MOUNT FAILED (rc=$rc)"
exit 1
