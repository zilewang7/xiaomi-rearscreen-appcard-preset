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

ZIP=$(sh "$MODDIR/logpack.sh" 2>/dev/null | tail -1)

if [ -n "$ZIP" ] && [ "$ZIP" != "FAILED" ]; then
    echo " 日志已保存到："
    echo "   $ZIP"
    echo
    echo " 把上面这个文件发给开发者即可。"
else
    echo " 日志打包失败。"
    echo " 可以手动把下面两份发给开发者："
    echo "   /data/local/tmp/rearscreen_appcard_preset.log"
    echo "   $MODDIR/product/media/rearscreen/appcard/default/rearScreen.json"
fi
echo "----------------------------------------------"

exit 0
