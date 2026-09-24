#!/usr/bin/env bash
#
# RearScreen AppCard Preset — 一键安装
#
# 用途：给国行小米手机（17 Pro / 17 Pro Max 等）的「应用卡中心」补上
#       ROM 缺失的预置应用卡（小米汽车 / 米家摄像机 / 股票行情 / 精选台历 /
#       临近日程 / 隐身模式）。
#
# 原理：应用卡中心的清单来自两处 ——
#         1) 服务端 store.assistant.miui.com/component/store/backPage
#         2) 本地预置 /system/media/rearscreen/appcard/default/rearScreen.json
#       18 系 ROM 自带第 2 项，17 系没有（parsePresetJson: file not found）。
#       本脚本把上游社区整理的预置卡注入该路径。
#
# 依赖：电脑端 adb、手机已 root（APatch / Magisk / KernelSU 均可）
#
# 用法：
#   ./scripts/install.sh [-s <serial>]
#   ADB=/path/to/adb ./scripts/install.sh
#
set -euo pipefail

# ---------------------------------------------------------------- 配置
MODULE_ID=reareye_appcard_preset
MODULE_DIR="/data/adb/modules/$MODULE_ID"

# 上游预置包（只下载，不在本仓库分发资源）
UPSTREAM_REPO="NekoStash/REAREye-Preset-Resources"
UPSTREAM_TAG="preset-v0.1.1"
RPP_NAME="reareye-presets-0.1.1.rpp"
RPP_SHA256="df1712404ad90e249867f230b21c510bf6fe705f83a8614f7ba6e786b31262f7"
RPP_URL="https://github.com/${UPSTREAM_REPO}/releases/download/${UPSTREAM_TAG}/${RPP_NAME}"

ADB="${ADB:-adb}"
SERIAL=""

# ---------------------------------------------------------------- 工具函数
c_red()   { printf '\033[31m%s\033[0m\n' "$*"; }
c_green() { printf '\033[32m%s\033[0m\n' "$*"; }
c_blue()  { printf '\033[36m%s\033[0m\n' "$*"; }
die() { c_red "错误：$*" >&2; exit 1; }

usage() {
    sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

# ---------------------------------------------------------------- 参数解析
while [ $# -gt 0 ]; do
    case "$1" in
        -s|--serial) SERIAL="${2:-}"; shift 2 ;;
        -h|--help)   usage ;;
        *) die "未知参数：$1（-h 查看用法）" ;;
    esac
done

ADB_CMD=("$ADB")
[ -n "$SERIAL" ] && ADB_CMD+=(-s "$SERIAL")

adb_() { "${ADB_CMD[@]}" "$@"; }

# ---------------------------------------------------------------- 1. 环境检查
c_blue "==> 检查 adb 与设备"
command -v "$ADB" >/dev/null 2>&1 || die "找不到 adb，请用 ADB=/path/to/adb 指定"
adb_ wait-for-device || die "没有检测到设备"
DEV_MODEL=$(adb_ shell getprop ro.product.marketname | tr -d '\r')
DEV_CODE=$(adb_ shell getprop ro.product.device | tr -d '\r')
DEV_ROM=$(adb_ shell getprop ro.build.version.incremental | tr -d '\r')
echo "    机型: ${DEV_MODEL:-未知} (${DEV_CODE:-?})    ROM: ${DEV_ROM:-?}"

c_blue "==> 检查 root"
if ! adb_ shell "su -c id" 2>/dev/null | grep -q "uid=0"; then
    die "设备没有 root 权限（需要 APatch / Magisk / KernelSU）"
fi
echo "    root: OK"

if ! adb_ shell "su -c '[ -d /data/adb/modules ]'" 2>/dev/null; then
    die "找不到 /data/adb/modules —— 请确认使用的是 APatch / Magisk / KernelSU"
fi

# ---------------------------------------------------------------- 2. 目标路径检查
c_blue "==> 检查目标路径"
REARSCREEN=$(adb_ shell "su -c 'ls -d /system/media/rearscreen 2>/dev/null'" | tr -d '\r')
[ -n "$REARSCREEN" ] || die "设备上没有 /system/media/rearscreen，本工具不适用"

if adb_ shell "su -c '[ -e /system/media/rearscreen/appcard/default/rearScreen.json ]'" 2>/dev/null; then
    c_green "    预置卡目录已存在，无需安装（或已被其它方案修复）"
    exit 0
fi
echo "    /system/media/rearscreen/appcard/ 不存在 —— 正是要修复的情况"

# ---------------------------------------------------------------- 3. 准备模块内容
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

c_blue "==> 下载上游预置包（约 62 MB）"
if [ ! -f "$WORK/$RPP_NAME" ]; then
    command -v curl >/dev/null 2>&1 || die "需要 curl"
    curl -fL --retry 3 -C - -o "$WORK/$RPP_NAME" "$RPP_URL" \
      || die "下载失败：$RPP_URL"
fi

c_blue "==> 校验 SHA-256"
ACTUAL=$(sha256sum "$WORK/$RPP_NAME" | cut -d' ' -f1)
[ "$ACTUAL" = "$RPP_SHA256" ] \
  || die "SHA-256 不匹配！\n  期望: $RPP_SHA256\n  实际: $ACTUAL\n  请确认上游发布未被篡改。"
c_green "    OK: $ACTUAL"

c_blue "==> 解包"
command -v unzip >/dev/null 2>&1 || die "需要 unzip"
unzip -q "$WORK/$RPP_NAME" -d "$WORK/rpp"
[ -d "$WORK/rpp/payload/appcard" ] || die "预置包结构异常（缺 payload/appcard）"

# ---------------------------------------------------------------- 4. 组装模块
c_blue "==> 组装模块"
MOD="$WORK/module"
mkdir -p "$MOD/product/media/rearscreen"
cp -a "$WORK/rpp/payload/appcard" "$MOD/product/media/rearscreen/appcard"

# 一并带上 ROM 原有的 template / wallpaper，避免 overlay 不合并时丢失
echo "    拉取设备原有 template / wallpaper"
adb_ shell "su -c 'cp -a /system/media/rearscreen/template /data/local/tmp/_tpl 2>/dev/null; cp -a /system/media/rearscreen/wallpaper /data/local/tmp/_wlp 2>/dev/null; cp -a /system/media/rearscreen/.nomedia /data/local/tmp/_nm 2>/dev/null; chmod -R 755 /data/local/tmp/_tpl /data/local/tmp/_wlp 2>/dev/null; chmod 644 /data/local/tmp/_nm 2>/dev/null; echo ok'" >/dev/null 2>&1 || true
for d in _tpl:template _wlp:wallpaper; do
    src=${d%%:*}; dst=${d##*:}
    if adb_ pull "/data/local/tmp/$src" "$MOD/product/media/rearscreen/$dst" >/dev/null 2>&1; then
        echo "      + $dst"
    fi
done
adb_ pull /data/local/tmp/_nm "$MOD/product/media/rearscreen/.nomedia" >/dev/null 2>&1 || true
adb_ shell "su -c 'rm -rf /data/local/tmp/_tpl /data/local/tmp/_wlp /data/local/tmp/_nm'" >/dev/null 2>&1 || true

# module.prop（版本号取自上游包版本）
cat > "$MOD/module.prop" <<EOF
id=$MODULE_ID
name=RearScreen AppCard Preset
version=0.1.1
versionCode=1
author=zilewang7
description=补上 ROM 缺失的背屏预置应用卡目录（小米汽车 / 米家摄像机 / 股票行情 / 日历日程 / 隐身模式）。资源来自 $UPSTREAM_REPO，本模块仅做路径注入。
EOF

# 脚本三个阶段各放一份（apd 会按阶段名查找 <module>/<stage>.sh）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for stage in post-fs-data service boot-completed; do
    cp "$SCRIPT_DIR/module/inject.sh" "$MOD/$stage.sh"
    chmod 755 "$MOD/$stage.sh"
done
chmod 644 "$MOD/module.prop"

# ---------------------------------------------------------------- 5. 推送
c_blue "==> 推送到设备"
adb_ shell "su -c 'rm -rf $MODULE_DIR'"
adb_ push "$MOD" "/data/local/tmp/_$MODULE_ID" >/dev/null
adb_ shell "su -c '
    mkdir -p /data/adb/modules
    rm -rf $MODULE_DIR
    mv /data/local/tmp/_$MODULE_ID $MODULE_DIR
    chown -R root:root $MODULE_DIR
    find $MODULE_DIR -type d -exec chmod 755 {} \;
    find $MODULE_DIR -type f -exec chmod 644 {} \;
    chmod 755 $MODULE_DIR/*.sh
    chcon -R u:object_r:system_file:s0 $MODULE_DIR/product/media/rearscreen
'" >/dev/null

adb_ shell "su -c 'ls $MODULE_DIR'"
c_green "==> 模块已安装：$MODULE_DIR"

# ---------------------------------------------------------------- 6. 立即生效（可选）
c_blue "==> 尝试立即生效（免重启）"
if adb_ shell "su -c 'sh $MODULE_DIR/post-fs-data.sh'" >/dev/null 2>&1; then
    if adb_ shell "su -c '[ -e /system/media/rearscreen/appcard/default/rearScreen.json ]'" 2>/dev/null; then
        c_green "    已立即生效"
    else
        c_red "    即时挂载未成功，重启后由 post-fs-data 阶段生效"
    fi
fi

echo
c_green "完成！"
echo "  1) 重启手机（让模块在 post-fs-data 阶段自动挂载）"
echo "  2) 重启后打开「设置 → 应用卡中心」查看，应出现："
echo "     天气日历(精选台历/临近日程) 实用工具(隐身模式) 智能车家(米家摄像机/小米汽车) 生活服务(股票行情)"
echo "  3) 排查日志：adb shell su -c cat /data/local/tmp/reareye_appcard_preset.log"
echo
echo "  卸载：./scripts/uninstall.sh"
