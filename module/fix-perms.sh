#!/system/bin/sh
# ============================================================================
# 把资源树的权限摆正：目录 755 / 文件 644
#
# 为什么需要这个脚本：
#   模块目录会被 bind mount 到 /product/media/rearscreen，背屏应用是以**自己的
#   uid**（u0_a140）去读的。而 curl -o 写出的是 0666 & ~umask、mkdir -p 是
#   0777 & ~umask —— 管理器的 WebUI exec 和部分开机脚本带 umask 077，
#   就会写出 0600 的文件和 0700 的目录，应用直接 EACCES。
#
#   真机上踩过：面板显示「23/31 就绪」，看着像只是缺文件，其实已经下到的那些
#   里有 8 个应用读不到，卡片一张都不显示。而 assets_progress 是拿 root 读的，
#   永远读得到，所以它报不出来。
#
# 输出：人类可读的几行；末行为 RESULT=ok|nothing|fail，供 WebUI 判断。
# ============================================================================

MODDIR=${0%/*}
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/rearscreen_appcard_preset

. "$MODDIR/lib.sh"
ns_reexec "$@"

SRC="$MODDIR/product/media/rearscreen"
[ -d "$SRC" ] || SRC="$MODDIR/system/media/rearscreen"

if [ ! -d "$SRC" ]; then
    echo "找不到资源目录：$SRC"
    echo "资源还没下载，先点「立即补齐资源」"
    echo "RESULT=nothing"
    exit 0
fi

BEFORE=$(count_unreadable "$SRC")
if [ "$BEFORE" -eq 0 ]; then
    echo "权限都正常，不用修"
    echo "RESULT=nothing"
    exit 0
fi

LEFT=$(fix_perms "$SRC")

echo "已修正资源权限"
echo "  · 修正前：$BEFORE 个条目应用读不到"
if [ "$LEFT" -eq 0 ]; then
    echo "  · 修正后：0 个（全部可读）"
else
    echo "  · 修正后：还剩 $LEFT 个读不到（可能需要重新下载）"
fi
echo
echo "已重启应用卡中心。打开背屏即可看到卡片。"

# 让应用重新读一遍；hook / 缓存都是进程级的
am force-stop com.miui.personalassistant >/dev/null 2>&1

if [ "$LEFT" -eq 0 ]; then
    echo "RESULT=ok"
else
    echo "RESULT=fail"
fi
