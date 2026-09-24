#!/system/bin/sh
# ============================================================================
# 开机执行：确保资源就绪 + 挂载预置卡目录（幂等）
#
# 三个阶段共用本脚本（构建时复制为 post-fs-data.sh / service.sh / boot-completed.sh）：
#   post-fs-data   — 最早，但此时无网络，仅尝试挂载
#   service        — 网络可用，资源缺失时在此补下载
#   boot-completed — 兜底
#
# 为什么不依赖 root 方案自己挂载模块文件：
#   APatch 把「模块文件挂载」委托给 metamodule（/data/adb/metamodule），很多机器没装，
#   于是模块文件根本不会被挂载；而模块目录下的阶段脚本一定会被执行。
#   所以在脚本里自行 bind mount，兼容 APatch / Magisk / KernelSU。
# ============================================================================

MODDIR=${0%/*}
[ -d "$MODDIR/product/media/rearscreen" ] || MODDIR=/data/adb/modules/rearscreen_appcard_preset

STAGE=${0##*/}
SRC="$MODDIR/product/media/rearscreen"
DST=/system/media/rearscreen
MARK="$DST/appcard/default/rearScreen.json"
LOG=/data/local/tmp/rearscreen_appcard_preset.log

log() { echo "[$(date '+%F %T')] $STAGE: $*" >> "$LOG" 2>/dev/null; }

# 1) 已生效 → 退出（脚本已跑过，或已装 metamodule 由它挂载）
[ -e "$MARK" ] && { log "已挂载，跳过"; exit 0; }

# 2) 资源缺失 → 联网补下载（post-fs-data 阶段无网络，交给后续阶段）
if [ ! -f "$SRC/appcard/default/rearScreen.json" ]; then
    [ "$STAGE" = "post-fs-data.sh" ] && { log "资源缺失；post-fs-data 无网络，等 service 阶段"; exit 0; }
    log "资源缺失，尝试补下载"
    . "$MODDIR/lib.sh"
    fetch_assets "$MODDIR/$MANIFEST_NAME" "$SRC" "$MODDIR/mirrors.txt" >> "$LOG" 2>&1 \
        || { log "下载失败，下次开机再试"; exit 1; }
fi

# 3) 等目标路径就绪
i=0
while [ "$i" -lt 60 ]; do [ -d "$DST" ] && break; sleep 1; i=$((i + 1)); done
[ -d "$DST" ] || { log "目标路径 $DST 未就绪"; exit 1; }

# 4) 修正 SELinux 上下文（否则 untrusted_app 读不到 → 表现为「挂上了但卡片不出现」）
chcon -R u:object_r:system_file:s0 "$SRC" 2>>"$LOG"

# 5) bind mount
mount --bind "$SRC" "$DST" 2>>"$LOG"

[ -e "$MARK" ] && { log "挂载成功"; exit 0; }
log "挂载失败"
exit 1
