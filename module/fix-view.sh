#!/system/bin/sh
# ============================================================================
# 把预设补进「应用视角」：往 init / zygote / 正在运行的目标应用各自的
# mount namespace 里各挂一次。
#
# 为什么需要这个脚本：
#   文件挂好、权限对、inode 也一致，并不等于应用读得到。应用进程都是 zygote
#   fork 出来的，而 zygote 在启动时就 unshare 了自己那份 mount namespace ——
#   挂载如果晚于那一刻，或者被 Root 方案在「应用变成 app uid」时按应用配置
#   「卸载模块」掉，应用读到的就还是 ROM 原文件：面板全绿、卡片全无。
#
#   补的顺序就是这条链：init → zygote → 正在运行的应用。前两层补上，之后 fork
#   的应用会自动继承；第三层是让已经在跑的应用立刻读到，不用重启。
#
# 注意：这是「让它现在生效」，不是「让它以后不再掉」—— 如果 Root 方案每次都在
# 应用启动时卸载模块（KernelSU 的「默认卸载模块」默认开着就是这种），得去设置里
# 关掉，否则重启应用后又会看不到。
#
# 输出：人类可读的几行；末行为 RESULT=ok|partial|fail|nothing，供 WebUI 判断。
# ============================================================================

MODDIR=${0%/*}
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/rearscreen_appcard_preset

. "$MODDIR/lib.sh"
ns_reexec "$@"

SRC="$MODDIR/product/media/rearscreen"
[ -d "$SRC" ] || SRC="$MODDIR/system/media/rearscreen"
DST="$APPCARD_DST"

if [ ! -d "$SRC" ]; then
    echo "找不到资源目录：$SRC"
    echo "资源还没下载，先点「立即补齐资源」"
    echo "RESULT=nothing"
    exit 0
fi

# 要补的几个视角：init、zygote、正在运行的目标应用
TARGETS="init:1"
for _z in $(ns_zygotes); do
    TARGETS="$TARGETS zygote:$_z"
done
for _pkg in com.miui.personalassistant com.xiaomi.subscreencenter com.android.thememanager; do
    for _p in $(pidof "$_pkg" 2>/dev/null); do
        TARGETS="$TARGETS ${_pkg##*.}:$_p"
    done
done

FIXED=0
SKIP=0
FAILN=0
for _t in $TARGETS; do
    _label=${_t%%:*}
    _pid=${_t#*:}
    [ -d "/proc/$_pid" ] || continue
    if [ "$(ns_state "$_pid" "$DST")" = ours ]; then
        SKIP=$((SKIP + 1))
        continue
    fi
    if ns_bind "$_pid" "$SRC" "$DST"; then
        echo "  · 已补进 $_label（pid $_pid）"
        FIXED=$((FIXED + 1))
    else
        echo "  · 补不进去 $_label（pid $_pid）"
        FAILN=$((FAILN + 1))
    fi
done

echo
echo "已补进 $FIXED 个视角，本来就正常 $SKIP 个，失败 $FAILN 个"

if [ "$FAILN" -gt 0 ]; then
    echo "补不进去的那些视角被 Root 方案隔离了；长期解法是在 Root 管理器里"
    echo "关掉「卸载模块 / 默认卸载模块」（KernelSU 默认是开的），或装 metamodule。"
fi

# 让应用重新读一遍预设（hook / 缓存都是进程级的）
am force-stop com.miui.personalassistant >/dev/null 2>&1

if [ "$FAILN" -gt 0 ] && [ "$FIXED" -eq 0 ]; then
    echo "RESULT=fail"
elif [ "$FAILN" -gt 0 ]; then
    echo "RESULT=partial"
elif [ "$FIXED" -eq 0 ]; then
    echo "RESULT=nothing"
else
    echo "RESULT=ok"
fi
exit 0
