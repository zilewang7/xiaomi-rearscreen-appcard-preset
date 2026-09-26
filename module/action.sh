#!/system/bin/sh
# ============================================================================
# 管理器模块卡片的「操作」按钮入口（APatch / KernelSU 都支持 action.sh）
#
# 没装 WebUI 宿主（WebUI X / KSU WebUI Standalone）的用户走这条路：
# 跑一遍诊断 → 打印结果 → 顺手生成日志包 → 告诉用户文件在哪
#
# 输出会被管理器捕捉并显示在「执行模块操作」界面里。
# ============================================================================

MODDIR=${0%/*}
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/rearscreen_appcard_preset

. "$MODDIR/lib.sh"
ns_reexec "$@"

MODVER=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null)

echo "=============================================="
echo " 背屏应用卡中心 · 状态自检"
echo " RearScreen AppCard Preset v${MODVER}"
echo "=============================================="
echo

sh "$MODDIR/status.sh" --text
echo

# ---- 顺手生成日志包，方便用户直接反馈 ----
echo "----------------------------------------------"
echo " 正在生成日志包…"
echo

SAVED=$(sh "$MODDIR/logpack.sh" 2>/dev/null | tail -1)

if [ -n "$SAVED" ] && [ "$SAVED" != "FAILED" ]; then
    SIZE=$(stat -c '%s' "$SAVED" 2>/dev/null || echo 0)
    echo " 日志已生成（$((SIZE / 1024)) KB）"
    echo
    echo " 位置：文件管理 → 内部存储 → Download"
    echo " 文件名：$(basename "$SAVED")"
    echo
    echo " （完整路径：$SAVED）"
    echo " 把这个文件发出来就行，不含账号信息。"
else
    echo " 日志生成失败。"
    echo " 请手动提供这两份："
    echo "   /data/local/tmp/rearscreen_appcard_preset.log"
    echo "   $MODDIR/product/media/rearscreen/appcard/default/rearScreen.json"
fi
echo "----------------------------------------------"

exit 0
