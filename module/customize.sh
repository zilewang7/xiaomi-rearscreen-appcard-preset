#!/system/bin/sh
# ============================================================================
# 安装时执行：拉取预置卡资源
#   $MODPATH 由 root 方案的模块安装器提供
# ============================================================================

MODPATH="${MODPATH:-$(cd "$(dirname "$0")" && pwd)}"
. "$MODPATH/lib.sh"

command -v ui_print >/dev/null 2>&1 || ui_print() { echo "$*"; }
command -v abort    >/dev/null 2>&1 || abort()    { echo "! $*" >&2; exit 1; }

VER=$(grep '^version=' "$MODPATH/module.prop" | cut -d= -f2)
ui_print " "
ui_print "***************************************"
ui_print "  RearScreen AppCard Preset  v${VER}"
ui_print "***************************************"
ui_print "  机型 : $(getprop ro.product.marketname) ($(getprop ro.product.device))"
ui_print "  系统 : $(getprop ro.build.version.incremental)"
ui_print " "

[ -d /system/media/rearscreen ] || {
    ui_print "! 本机没有 /system/media/rearscreen"
    abort "不支持的设备"
}

DEST="$MODPATH/product/media/rearscreen"
mkdir -p "$DEST"

ui_print "- 拉取预置卡资源（31 个文件 / 约 7 MB）"
ui_print "  上游: github.com/${UPSTREAM_REPO}"
ui_print "  直连优先，失败自动切换镜像"

if fetch_assets "$MODPATH/$MANIFEST_NAME" "$DEST" "$MODPATH/mirrors.txt" 2>&1 \
        | while IFS= read -r l; do ui_print "  $l"; done; then
    ui_print "- 资源就绪"
else
    ui_print "! 部分资源下载失败（网络受限？）"
    ui_print "  模块已安装，开机联网后会自动补齐。"
fi

# 保留 ROM 原有内容（防止某些 root 方案 overlay 不合并导致 template/wallpaper 丢失）
for item in template wallpaper .nomedia; do
    if [ -e "/system/media/rearscreen/$item" ] && [ ! -e "$DEST/$item" ]; then
        cp -a "/system/media/rearscreen/$item" "$DEST/" 2>/dev/null \
            && ui_print "- 已保留 ROM 原有 $item"
    fi
done

if command -v set_perm_recursive >/dev/null 2>&1; then
    set_perm_recursive "$MODPATH" 0 0 0755 0644 2>/dev/null || true
    for s in post-fs-data.sh service.sh boot-completed.sh customize.sh; do
        [ -f "$MODPATH/$s" ] && set_perm "$MODPATH/$s" 0 0 0755 2>/dev/null || true
    done
else
    chown -R 0:0 "$MODPATH" 2>/dev/null || true
    find "$MODPATH" -type d -exec chmod 755 {} \; 2>/dev/null || true
    find "$MODPATH" -type f -exec chmod 644 {} \; 2>/dev/null || true
    chmod 755 "$MODPATH"/*.sh 2>/dev/null || true
fi

ui_print " "
ui_print "- 安装完成，重启后生效"
ui_print " "
