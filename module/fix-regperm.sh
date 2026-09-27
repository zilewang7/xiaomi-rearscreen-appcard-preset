#!/system/bin/sh
# ============================================================================
# 修好「背屏卡片存不下盘」：把背屏状态文件的属主/权限改成背屏应用自己
#
# 为什么需要它（真机上定案的那一类故障）：
#   点「添加」时应用会把卡片写进
#     /data/system/theme_magic/users/<u>/subscreencenter/config/appInfo.json
#   如果这个文件的属主不是背屏应用（被 root 工具、备份还原、清理类模块动过），
#   应用就既改不动它的权限、也写不进去，于是：
#     insertApp 成功（进了内存） → Write ... failed → SaveAppInfo, saved = false
#   表现就是「点添加提示成功、背屏却没变化」，重启后张数还回到原样。
#   同一个目录下的 widget.json 属主正常，所以它写得进去 —— 差别只在这一个文件。
#
# 只改属主/权限，**不动内容**：用户的卡片清单要保住。
#
# 输出：人类可读的几行；末行为 RESULT=ok|nothing|fail，供 WebUI 判断。
# ============================================================================

MODDIR=${0%/*}
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/rearscreen_appcard_preset

. "$MODDIR/lib.sh"
ns_reexec "$@"

THEME_DIR=$(theme_dir)
AUID=$(stat -c '%u' /data/data/com.xiaomi.subscreencenter 2>/dev/null)
AGID=$(stat -c '%g' /data/data/com.xiaomi.subscreencenter 2>/dev/null)

if [ -z "$THEME_DIR" ] || [ ! -d "$THEME_DIR" ]; then
    echo "找不到背屏状态目录（theme_magic），这台机器可能没有背屏卡片这一套"
    echo "RESULT=nothing"
    exit 0
fi
if [ -z "$AUID" ]; then
    echo "读不到背屏应用（com.xiaomi.subscreencenter）的 uid，无法判断属主该是谁"
    echo "RESULT=fail"
    exit 0
fi

FIXED=0
BAD=0
FIRST_BAD=""
for f in $(find "$THEME_DIR" -type f 2>/dev/null); do
    [ -f "$f" ] || continue
    OU=$(stat -c '%u' "$f" 2>/dev/null)
    [ "$OU" = "$AUID" ] && continue
    BAD=$((BAD + 1))
    [ -z "$FIRST_BAD" ] && FIRST_BAD="$f"
    echo "  · $(echo "$f" | sed "s#$THEME_DIR/##")  属主 $(stat -c '%u:%g %a' "$f" 2>/dev/null) → 应为 $AUID:$AGID 777"
    if chown "$AUID:$AGID" "$f" 2>/dev/null && chmod 777 "$f" 2>/dev/null; then
        FIXED=$((FIXED + 1))
    fi
done

echo
if [ "$BAD" -eq 0 ]; then
    echo "背屏状态文件的属主都正常（都是背屏应用自己的），不用修"
    echo "RESULT=nothing"
    exit 0
fi

echo "共发现 $BAD 个文件属主不对，已修正 $FIXED 个（内容未改动）"

REG="$THEME_DIR/config/appInfo.json"
if [ -f "$REG" ]; then
    if subscreen_state_writable "$REG"; then
        echo "  · appInfo.json 现在：$(stat -c '%u:%g %a' "$REG" 2>/dev/null) —— 背屏应用可以写了"
        # 让应用重新读一遍：它内存里那份（加了但没存下的卡）和盘上不一致
        am force-stop com.xiaomi.subscreencenter >/dev/null 2>&1
        echo
        echo "已重启背屏服务。回到应用卡中心再点一次「添加」，这次背屏上就会出现。"
        echo "RESULT=ok"
    else
        echo "  · appInfo.json 仍然是 $(stat -c '%u:%g %a' "$REG" 2>/dev/null)，没修成功"
        echo "RESULT=fail"
    fi
elif [ "$FIXED" -gt 0 ]; then
    echo "RESULT=ok"
else
    echo "RESULT=fail"
fi
exit 0
