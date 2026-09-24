#!/usr/bin/env bash
#
# RearScreen AppCard Preset — 卸载
#
# 用法：./scripts/uninstall.sh [-s <serial>]
#
set -euo pipefail

MODULE_ID=reareye_appcard_preset
ADB="${ADB:-adb}"
SERIAL=""

while [ $# -gt 0 ]; do
    case "$1" in
        -s|--serial) SERIAL="${2:-}"; shift 2 ;;
        -h|--help)   sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数：$1" >&2; exit 1 ;;
    esac
done

ADB_CMD=("$ADB"); [ -n "$SERIAL" ] && ADB_CMD+=(-s "$SERIAL")
adb_() { "${ADB_CMD[@]}" "$@"; }

echo "==> 检查设备"
adb_ wait-for-device
adb_ shell "su -c id" 2>/dev/null | grep -q "uid=0" || { echo "需要 root" >&2; exit 1; }

echo "==> 卸载模块 $MODULE_ID"
adb_ shell "su -c '
    umount /system/media/rearscreen 2>/dev/null
    rm -rf /data/adb/modules/$MODULE_ID
    rm -f /data/local/tmp/reareye_appcard_preset.log
'"

echo "==> 恢复智能助理（清除已解析的预置清单）"
adb_ shell "am force-stop com.miui.personalassistant" 2>/dev/null || true

echo
echo "完成。建议重启一次让改动完全生效。"
echo "重启后 /system/media/rearscreen/appcard 应消失，应用卡中心回到 ROM 原始清单。"
