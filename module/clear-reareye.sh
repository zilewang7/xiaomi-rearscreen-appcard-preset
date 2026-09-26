#!/system/bin/sh
# ============================================================================
# 清除 REAREye 已提交的预设资源包，让它的文件重定向钩子失效。
#
# 背景：REAREye（LSPosed）的 PresetPackFilesHook 会把三个目标应用对
# /system/media/rearscreen 的读取全部重定向到它自己的 RPP 快照。只要它提交过
# 预设包，本模块 bind mount 的文件就永远不会被读到 —— 状态面板全绿但卡片不出现。
# 详见 docs/reareye-conflict.md
#
# 这里只删「快照缓存」，不碰 REAREye 应用本体、也不碰它的其他设置：
# 删完 store.load() 返回 false，钩子自动失效，读取回到真实文件系统。
#
# 输出：人类可读的几行；末行为 RESULT=ok|nothing|fail，供 WebUI 判断。
# ============================================================================

MODDIR=${0%/*}
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/rearscreen_appcard_preset

. "$MODDIR/lib.sh"
ns_reexec "$@"

PA_PKG=com.miui.personalassistant
TARGETS="com.xiaomi.subscreencenter com.android.thememanager $PA_PKG"

removed=""
bytes=0

for p in $TARGETS; do
    d="/data/data/$p/cache/reareye-preset-pack"
    [ -d "$d" ] || continue

    # du 在部分设备上对 /data/data 要 root；失败就退化成只报个数
    sz=$(du -sk "$d" 2>/dev/null | awk '{print $1}')
    [ -n "$sz" ] && bytes=$((bytes + sz))

    if rm -rf "$d" 2>/dev/null && [ ! -e "$d" ]; then
        removed="$removed $p"
    else
        echo "无法删除：$d"
        echo "RESULT=fail"
        exit 1
    fi
done

if [ -z "$removed" ]; then
    echo "没有找到 REAREye 的预设资源包（本来就没提交过）"
    echo "RESULT=nothing"
    exit 0
fi

# 第一行只是标题：状态页会把脚本输出当正文显示，卡片标题已经写了「已清除」，
# 这里再重复一遍会念起来很啰嗦。
echo "已删除："
for p in $removed; do echo "  · $p"; done
if [ "$bytes" -ge 1024 ]; then
    echo "释放空间：$((bytes / 1024)) MB"
elif [ "$bytes" -gt 0 ]; then
    echo "释放空间：${bytes} KB"
fi

# hook 是进程级的：只要目标应用重启，读取就会回到真实文件系统
am force-stop "$PA_PKG" >/dev/null 2>&1
echo
echo "已重启应用卡中心。打开背屏即可看到卡片。"
echo "（若仍不显示，重启一次手机再试）"
echo "RESULT=ok"
