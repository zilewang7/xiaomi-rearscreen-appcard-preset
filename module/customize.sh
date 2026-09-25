#!/system/bin/sh
# ============================================================================
# 安装时执行：拉取预置卡资源
#   $MODPATH 由 root 方案的模块安装器提供
#
# 关于「安装卡住」（社区反馈过）：
#   旧版是逐个文件串行下载、没有单文件超时、也没有整体预算，镜像一卡就整个
#   安装界面卡死。现在：单文件 25s 硬超时 + 整体 100s 预算 + 4 路并发 + 镜像
#   轮换 + 网络不可达提前退出。预算用尽也照样装完，剩下的重启后自动补。
# ============================================================================

MODPATH="${MODPATH:-$(cd "$(dirname "$0")" && pwd)}"
. "$MODPATH/lib.sh"

command -v ui_print >/dev/null 2>&1 || ui_print() { echo "$*"; }
command -v abort    >/dev/null 2>&1 || abort()    { echo "! $*" >&2; exit 1; }

# 安装器的输出通道是 ui_print，覆盖掉 lib.sh 里的 echo 版本
log() { ui_print "[appcard] $*"; }

VER=$(sed -n 's/^version=//p' "$MODPATH/module.prop")

ui_print " "
ui_print "***************************************"
ui_print "  RearScreen AppCard Preset  v${VER}"
ui_print "***************************************"
ui_print "  机型 : $(getprop ro.product.marketname) ($(getprop ro.product.device))"
ui_print "  系统 : $(getprop ro.build.version.incremental)"
ui_print " "

# ---------------------------------------------------------------- 设备检查
[ -d /system/media/rearscreen ] || {
    ui_print "! 本机没有 /system/media/rearscreen"
    abort "不支持的设备（本模块只面向小米 17 Pro / 17 Pro Max 背屏）"
}

DEST="$MODPATH/product/media/rearscreen"
mkdir -p "$DEST"

# ---------------------------------------------------------------- 记录 ROM 原始状态
# 用来判断「ROM 自己是否已经有这套卡片」。小米承诺 12 月底给 17 系列推送，
# 推了之后本模块就该退休了，用户在状态页能直接看到这个判断。
if [ -e /system/media/rearscreen/appcard/default/rearScreen.json ]; then
    echo "ROM 出厂已自带 appcard 预设" > "$MODPATH/.rom_had_preset"
    if grep -q 'com.mi.car.mobile' /system/media/rearscreen/appcard/default/rearScreen.json 2>/dev/null; then
        echo "且已包含小米汽车卡片" >> "$MODPATH/.rom_had_preset"
    fi
fi

# ---------------------------------------------------------------- 拉取资源
ui_print "- 拉取预置卡资源（31 个文件 / 约 7 MB）"
ui_print "  上游: github.com/${UPSTREAM_REPO}"
ui_print "  策略: 直连优先 → 镜像回退，逐个校验 SHA-256"
ui_print "  预算: 最多 ${INSTALL_BUDGET} 秒，超时也不影响安装完成"
ui_print " "

if fetch_assets "$MODPATH/$MANIFEST_NAME" "$DEST" "$MODPATH/mirrors.txt" "$FETCH_JOBS" "$INSTALL_BUDGET"; then
    ui_print " "
    ui_print "- 资源已全部就绪"
else
    ui_print " "
    ui_print "- 资源尚未下全（网络受限/超时），不影响安装"
    ui_print "  重启联网后会自动补齐；也可以稍后在状态页点「立即补齐」"
fi

# ---------------------------------------------------------------- 保留 ROM 原有内容
# 我们挂的是整个 rearscreen 目录，不把 ROM 原有的 template/wallpaper 带过来会丢东西
for item in template wallpaper .nomedia; do
    if [ -e "/system/media/rearscreen/$item" ] && [ ! -e "$DEST/$item" ]; then
        cp -a "/system/media/rearscreen/$item" "$DEST/" 2>/dev/null \
            && ui_print "- 已保留 ROM 原有的 $item"
    fi
done

# ---------------------------------------------------------------- 权限
if command -v set_perm_recursive >/dev/null 2>&1; then
    set_perm_recursive "$MODPATH" 0 0 0755 0644 2>/dev/null || true
    for s in post-fs-data.sh service.sh boot-completed.sh customize.sh \
             action.sh status.sh logpack.sh fetch.sh lib.sh; do
        [ -f "$MODPATH/$s" ] && set_perm "$MODPATH/$s" 0 0 0755 2>/dev/null || true
    done
else
    chown -R 0:0 "$MODPATH" 2>/dev/null || true
    find "$MODPATH" -type d -exec chmod 755 {} \; 2>/dev/null || true
    find "$MODPATH" -type f -exec chmod 644 {} \; 2>/dev/null || true
    chmod 755 "$MODPATH"/*.sh 2>/dev/null || true
fi

# webroot 给管理器的 WebView 读，显式放开
[ -d "$MODPATH/webroot" ] && chmod 755 "$MODPATH/webroot" && chmod 644 "$MODPATH/webroot"/* 2>/dev/null

ui_print " "
ui_print "- 安装完成"
ui_print " "
ui_print "  重启后在管理器里点开本模块卡片，即可看到状态面板；"
ui_print "  没有 WebUI 宿主的话，点模块卡片的「操作」按钮也能看到诊断。"
ui_print " "
