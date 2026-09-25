#!/system/bin/sh
# ============================================================================
# 手动补齐资源（WebUI「立即补齐」按钮 / action.sh 都会调它）
#
# 补齐后不需要重新挂载：/product/media/rearscreen 是对模块目录的 bind mount，
# 目录里新增文件立刻可见。只是应用可能缓存了旧列表，需要重启应用卡中心。
# ============================================================================

MODDIR=${0%/*}
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/rearscreen_appcard_preset

. "$MODDIR/lib.sh"

LOG=/data/local/tmp/rearscreen_appcard_preset.log
SRC="$MODDIR/product/media/rearscreen"

{
    echo "[$(date '+%F %T')] fetch.sh: 收到补齐请求"
    refresh_mirrors "$MODDIR/mirrors.txt"
    fetch_assets "$MODDIR/$MANIFEST_NAME" "$SRC" "$MODDIR/mirrors.txt" "$FETCH_JOBS" 0
    rc=$?
    set -- $(assets_progress "$MODDIR/$MANIFEST_NAME" "$SRC")
    echo "[$(date '+%F %T')] fetch.sh: 结束 rc=$rc，进度 ${1}/${2}"
} >> "$LOG" 2>&1

exit 0
