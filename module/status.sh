#!/system/bin/sh
# ============================================================================
# 诊断引擎：检查模块是否真的生效，并直接告诉用户「下一步该做什么」
#
# 用法：
#   status.sh            输出行协议（WebUI 解析用）
#   status.sh --text     输出人类可读报告（action.sh / 终端用）
#
# 行协议（记录以 @@ 开头，字段一行一个，值内换行已压平）：
#   @@
#   id=<检查项标识>
#   level=ok|warn|fail|info
#   title=<标题>
#   detail=<详情>
#   fix=<修复建议，可为空>
#
# 设计说明见 docs/status-page.md
# ============================================================================

MODDIR=${0%/*}
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/rearscreen_appcard_preset

. "$MODDIR/lib.sh"
ns_reexec "$@"

MODE="${1:-}"

MOD_SRC="$MODDIR/product/media/rearscreen"
DST="/system/media/rearscreen"          # 等价于 /product/media/rearscreen
MARK="$DST/appcard/default/rearScreen.json"
SRC_MARK="$MOD_SRC/appcard/default/rearScreen.json"
INJ_LOG=/data/local/tmp/rearscreen_appcard_preset.log
PA_PKG=com.miui.personalassistant

[ -f "$MODDIR/$CATALOG_NAME" ] && CATALOG="$MODDIR/$CATALOG_NAME" || CATALOG=""

OUT=/data/local/tmp/.appcard_status_$$.txt
: > "$OUT"

# ------------------------------------------------------------------ 记录
emit() {  # $1=id $2=level $3=title $4=detail $5=fix $6=pkg(可选，WebUI 显示应用图标) $7=action(可选，WebUI 显示修复按钮)
    printf '@@\nid=%s\nlevel=%s\ntitle=%s\ndetail=%s\nfix=%s\npkg=%s\naction=%s\n' \
        "$1" "$2" "$3" \
        "$(printf '%s' "$4" | tr '\n\r\t' '   ')" \
        "$(printf '%s' "$5" | tr '\n\r\t' '   ')" \
        "$6" "${7:-}" >> "$OUT"
}

# 一次拿全所有包名+版本号（pm list 0.08s，逐个 pm dump 要 1.75s/个）
PKGS=$(pm list packages --show-versioncode 2>/dev/null)

pkg_installed() { printf '%s\n' "$PKGS" | grep -q "^package:$1 "; }
pkg_version()   { printf '%s\n' "$PKGS" | sed -n "s/^package:$1 versionCode:\([0-9]*\).*/\1/p" | head -1; }

is_num() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# ============================================================ 1. 环境
emit env.device info "设备" \
    "$(getprop ro.product.model) / $(getprop ro.product.device)" ""

emit env.os info "系统" \
    "$(getprop ro.mi.os.version.name) ($(getprop ro.build.version.incremental))" ""

if [ -d /data/adb/ap ] || [ -n "$APATCH" ]; then
    ROOT_SCHEME="APatch"
elif [ -d /data/adb/ksu ]; then
    ROOT_SCHEME="KernelSU"
elif command -v magisk >/dev/null 2>&1; then
    ROOT_SCHEME="Magisk $(magisk -v 2>/dev/null)"
else
    ROOT_SCHEME="未识别"
fi
META="未装（模块文件不会被自动挂载，本模块因此自行 bind mount）"
if [ -e /data/adb/metamodule ]; then
    META="已装（$(sed -n 's/^id=//p' /data/adb/metamodule/module.prop 2>/dev/null)）"
fi
emit env.root info "Root 方案" "$ROOT_SCHEME；metamodule：$META" ""

emit env.module ok "模块版本" "v$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null)" ""

# ============================================================ 2. 冲突检测
# REAREye 是另一个背屏增强模块（LSPosed）。它的 PresetPackFilesHook 会把
# com.miui.personalassistant 对系统预置路径的所有访问（File.exists / FileInputStream /
# Os.open / ZipFile）重定向到它自己的 RPP 快照。一旦它提交过预设包，
# 本模块挂上去的文件就再也不会被读到 —— 表现为「所有检查都通过，卡片就是不出现」。
# 这坑很隐蔽，所以单独查、单独说。
REAREYE_PKG=hk.uwu.reareye
# REAREye 用「被 hook 的那个应用」的 dataDir 作基准，而目标应用有三个，
# 所以每个都要查 —— 只查应用卡中心会漏判（本模块曾因此误报“全绿”）。
#   <dir>/<hash>/active.rpp 存在  → store.load() 真的会返回 true，钩子生效 = 已接管
#   目录存在但没有 active.rpp     → 下载/校验没走完，还没接管，但随时会
CONF_ACTIVE=""
CONF_LEFTOVER=""
for _p in com.xiaomi.subscreencenter com.android.thememanager com.miui.personalassistant; do
    _d="/data/data/$_p/cache/reareye-preset-pack"
    [ -d "$_d" ] || continue
    CONF_LEFTOVER="$CONF_LEFTOVER$_p "
    if ls "$_d"/*/active.rpp >/dev/null 2>&1; then
        CONF_ACTIVE="$CONF_ACTIVE$_p "
    fi
done

if [ -n "$CONF_ACTIVE" ]; then
    emit conf.reareye fail "REAREye 冲突" \
        "REAREye 已接管预置路径（${CONF_ACTIVE% }），本模块挂上去的文件不会被读取" \
        "二选一：① 用 REAREye 自带的「预设资源包」，同时卸载本模块；② 点下面的按钮清除 REAREye 的预设资源包，重启后本模块即可生效" \
        "" "clear_reareye"
elif [ -n "$CONF_LEFTOVER" ]; then
    emit conf.reareye warn "REAREye 残留" \
        "发现未完成的预设资源包（${CONF_LEFTOVER% }），当前还没接管，但下载完成就会接管" \
        "若卡片不出现，可点下面的按钮清除它，然后重启" \
        "" "clear_reareye"
elif pkg_installed "$REAREYE_PKG"; then
    emit conf.reareye warn "REAREye 已安装" \
        "没有提交过预设资源包，当前不冲突；一旦启用，本模块会立刻失效" \
        "若卡片不出现，先去 REAREye → 关于 →「预设资源包」确认没有启用"
else
    emit conf.reareye ok "冲突检测" "未安装 REAREye，无冲突" ""
fi

# ============================================================ 3. 资源
set -- $(assets_progress "$MODDIR/$MANIFEST_NAME" "$MOD_SRC")
READY=${1:-0}; TOTAL=${2:-0}
PERMBAD=$(perm_issues "$MODDIR/$MANIFEST_NAME" "$MOD_SRC")
PERM_DETAIL=""
[ "${PERMBAD:-0}" -gt 0 ] && PERM_DETAIL=$(perm_detail "$MODDIR/$MANIFEST_NAME" "$MOD_SRC")

if [ "$TOTAL" -eq 0 ]; then
    emit res.progress fail "资源完整性" "清单缺失或为空" \
        "重新刷入模块 zip；若仍失败请导出日志反馈"
elif [ "$READY" -eq "$TOTAL" ]; then
    # 「文件都在」和「应用读得到」分开报：前者是下载问题，后者是权限问题，
    # 混在一条里的话，只缺权限时这一行会整个消失，用户以为检查没做。
    if [ "${PERMBAD:-0}" -eq 0 ]; then
        emit res.progress ok "资源完整性" "$READY/$TOTAL 个文件全部校验通过，应用可读" ""
    else
        emit res.progress ok "资源完整性" "$READY/$TOTAL 个文件全部下载完成（权限问题见下一项）" ""
    fi
elif [ "$READY" -eq 0 ]; then
    emit res.progress fail "资源完整性" "0/$TOTAL，一个都没下载成功" \
        "网络连不上 GitHub 也连不上所有镜像：开代理或换 WiFi 后重启，会自动补齐"
elif [ "$READY" -lt "$TOTAL" ]; then
    emit res.progress warn "资源完整性" "$READY/$TOTAL，还差 $((TOTAL - READY)) 个" \
        "重启后会自动补齐；也可点「立即补齐」"
fi

# 文件都在、但应用读不到 —— 这是「面板看着没问题、卡片就是不出现」的另一大元凶。
# 注意这条检查必须用「别人能不能读」的判据，不能像 assets_progress 那样拿 root 去读：
# root 读得到 0600 的文件，于是检查永远通过。
if [ "${PERMBAD:-0}" -gt 0 ]; then
    emit res.perm fail "资源权限" \
        "$PERMBAD 个文件/目录应用读不到（root 读得到，背屏应用读不到）${PERM_DETAIL:+；如 $PERM_DETAIL}" \
        "点下面的按钮就地修好，不用重启" \
        "" "fix_perms"
fi

if [ -f "$MIRROR_CACHE" ]; then
    DAYS=$(( ($(date +%s) - $(date -r "$MIRROR_CACHE" +%s 2>/dev/null || echo 0)) / 86400 ))
    emit res.mirror info "镜像列表" "远程列表，${DAYS} 天前更新，共 $(grep -c . "$MIRROR_CACHE") 条" ""
else
    emit res.mirror info "镜像列表" "模块内置列表（远程列表尚未拉到，不影响使用）" ""
fi

# ============================================================ 4. 注入状态
if [ ! -e "$MARK" ]; then
    emit inj.mount fail "预设挂载" "$DST 下读不到 rearScreen.json，预设没挂上" \
        "重启设备；仍失败请点「导出日志」反馈"
else
    DST_INO=$(stat -c '%d:%i' "$MARK" 2>/dev/null)
    SRC_INO=$(stat -c '%d:%i' "$SRC_MARK" 2>/dev/null)
    if [ -n "$DST_INO" ] && [ "$DST_INO" = "$SRC_INO" ]; then
        emit inj.mount ok "预设挂载" "已挂载，inode $DST_INO 与模块内文件一致" ""
    else
        emit inj.mount warn "预设挂载" "$DST 有文件，但不是本模块的内容（inode 不一致）" \
            "可能是 ROM 自带或其它模块占用，可先卸载本模块对比"
    fi

    CTX=$(ls -Z "$MARK" 2>/dev/null | awk '{print $1}')
    case "$CTX" in
        *system_file*) emit inj.context ok "SELinux 上下文" "$CTX" "" ;;
        *)             emit inj.context warn "SELinux 上下文" "${CTX:-读取失败}" \
                           "上下文不对应用可能读不到，重启设备让其重新挂载" ;;
    esac

    SZ=$(stat -c '%s' "$MARK" 2>/dev/null)
    if is_num "$SZ" && [ "$SZ" -gt 1000 ]; then
        emit inj.readable ok "预设可读性" "${SZ} 字节，可读" ""
    else
        emit inj.readable fail "预设可读性" "文件异常（大小 ${SZ:-0} 字节）" "重新下载资源"
    fi
fi

# 走 /system/media 这条 symlink 再验一次 —— 应用就是这么读的
if [ -e /system/media/rearscreen/appcard/default/rearScreen.json ]; then
    emit inj.symlink ok "应用读取路径" "/system/media/rearscreen 可访问（软链到 /product/media）" ""
else
    emit inj.symlink fail "应用读取路径" "/system/media/rearscreen 读不到预设" \
        "/system/media 是指向 /product/media 的软链，读不到说明挂载点不对"
fi

# 上面所有检查都是「root 视角」。但应用有自己的 mount namespace（Android 给每个
# 应用 unshare 一份），挂载如果发生在 zygote 分叉之后，应用那边根本看不到。
# 所以最后真的进到应用进程的 namespace 里读一次 —— 这才是应用眼里的世界。
# 顺带也能验 DAC：stat 用的是 root，验权限还得靠上面的 res.perm。
PA_PID=$(pidof "$PA_PKG" 2>/dev/null | awk '{print $1}')
if [ -n "$PA_PID" ] && command -v nsenter >/dev/null 2>&1; then
    APP_INO=$(nsenter -t "$PA_PID" -m -- stat -c '%d:%i' "$MARK" 2>/dev/null)
    SRC_INO2=$(stat -c '%d:%i' "$SRC_MARK" 2>/dev/null)
    if [ -z "$APP_INO" ]; then
        emit inj.appns warn "应用视角" "进不去应用进程的 namespace，无法确认应用看到的是哪份文件" \
            "不影响使用；若卡片不出现，重启设备后本项会重新检测"
    elif [ "$APP_INO" = "$SRC_INO2" ]; then
        emit inj.appns ok "应用视角" "应用卡中心（pid $PA_PID）读到的就是本模块的文件" ""
    else
        emit inj.appns fail "应用视角" \
            "应用卡中心读到的**不是**本模块的文件（应用 inode $APP_INO / 模块 inode $SRC_INO2）" \
            "挂载没进到应用的 mount namespace：重启设备（挂载要在 zygote 之前完成）"
    fi
elif [ -z "$PA_PID" ]; then
    emit inj.appns info "应用视角" "应用卡中心未运行，跳过（打开背屏后再检测）" ""
fi

if [ -f "$INJ_LOG" ]; then
    # 注意：busybox grep 的 BRE 不支持 \| 交替，必须用 -E
    if grep -qE '挂载成功|已挂载' "$INJ_LOG" 2>/dev/null; then
        emit inj.stagelog ok "开机脚本" "有成功记录：$(tail -1 "$INJ_LOG")" ""
    else
        emit inj.stagelog warn "开机脚本" "日志存在但没有成功记录：$(tail -1 "$INJ_LOG")" "重启设备"
    fi
else
    emit inj.stagelog warn "开机脚本" "没有开机日志，阶段脚本可能没执行过" "重启设备；仍无日志请导出日志反馈"
fi

# ============================================================ 5. 预设内容
CATCOUNT=0; CARDCOUNT=0
if [ -e "$MARK" ]; then
    CATCOUNT=$(grep -o '"categoryName"' "$MARK" 2>/dev/null | wc -l | tr -d ' ')
    CARDCOUNT=$(grep -o '"bindApp"' "$MARK" 2>/dev/null | wc -l | tr -d ' ')
fi
if is_num "$CARDCOUNT" && [ "$CARDCOUNT" -gt 0 ]; then
    emit pre.content ok "预设内容" "$CATCOUNT 个分类 / $CARDCOUNT 张卡片" ""
else
    emit pre.content fail "预设内容" "解析不出卡片" "资源可能损坏，重新下载"
fi

# ============================================================ 6. 卡片就绪度（最关键）
# 应用卡中心会自己过滤掉依赖不满足的卡片 —— 预设挂对了，App 没装，卡片照样不出现。
# 这是「装了模块但没效果」的头号原因，所以逐张卡片查依赖。
if [ -n "$CATALOG" ]; then
    N=0
    while IFS='|' read -r cat name pkg minver respath; do
        case "$cat" in ''|\#*) continue ;; esac
        [ -n "$pkg" ] || continue
        N=$((N + 1))

        [ -f "$MOD_SRC/$respath" ] && res="资源已就绪" || res="资源缺失"

        if ! pkg_installed "$pkg"; then
            emit "card.$N" fail "$name" \
                "配套 App 未安装：$pkg" \
                "装上它这张卡才会出现；$res" "$pkg"
            continue
        fi

        have=$(pkg_version "$pkg")
        if [ -z "$minver" ] || [ "$minver" = "0" ]; then
            emit "card.$N" ok "$name" "$pkg $have ✓；$res" "" "$pkg"
        elif is_num "$have" && [ "$have" -ge "$minver" ]; then
            emit "card.$N" ok "$name" "$pkg $have ≥ $minver ✓；$res" "" "$pkg"
        else
            emit "card.$N" fail "$name" \
                "App 版本过低：$have < 需要 $minver" \
                "升级 $pkg 后卡片才会出现；$res" "$pkg"
        fi
    done < "$CATALOG"
fi

# ============================================================ 7. 应用卡中心
PAV=$(pkg_version "$PA_PKG")
if [ -n "$PAV" ]; then
    emit app.pa ok "应用卡中心" "$PA_PKG $PAV" ""
else
    emit app.pa fail "应用卡中心" "$PA_PKG 未安装" "本模块对这台设备无效"
fi

if ps -A 2>/dev/null | grep -q "$PA_PKG"; then
    emit app.running info "应用卡中心进程" "运行中" \
        "刚刷完模块需重启手机，或点「重启应用卡中心」让它重新读取预设"
else
    emit app.running info "应用卡中心进程" "未运行（打开背屏即会拉起）" ""
fi

# ============================================================ 8. 结论
OKN=$(grep -c '^level=ok$'   "$OUT" 2>/dev/null)
WARN=$(grep -c '^level=warn$' "$OUT" 2>/dev/null)
FAIL=$(grep -c '^level=fail$' "$OUT" 2>/dev/null)
OKN=${OKN:-0}; WARN=${WARN:-0}; FAIL=${FAIL:-0}

if [ "$FAIL" -gt 0 ]; then
    emit result.next fail "结论" "$FAIL 项不通过、$WARN 项需注意" \
        "先看标红的项；卡片不出现最常见的原因是配套 App 没装或版本不够"
elif [ "$WARN" -gt 0 ]; then
    # 有 warn 就不能说「全部通过」—— 面板顶部徽章会显示「N 项注意」，
    # 结论却写「全部检查通过」，两处自相矛盾，用户只会更糊涂。
    emit result.next warn "结论" "主要检查通过（$OKN 项正常），有 $WARN 项需注意" \
        "看标黄的项；卡片不出现的话，多半就是那一条"
else
    emit result.next ok "结论" "全部检查通过（$OKN 项正常）" \
        "若背屏仍看不到卡片：重启手机后重新打开应用卡中心"
fi

# ============================================================ 输出
if [ "$MODE" = "--text" ]; then
    RENDER_LAST=""
    render_one() {  # 用当前 id/level/title/detail/fix 输出一行
        [ -n "$id" ] || return 0
        case "$level" in
            ok)   mark="✓" ;;
            warn) mark="!" ;;
            fail) mark="✗" ;;
            *)    mark="·" ;;
        esac
        printf '  %s %s\n      %s\n' "$mark" "$title" "$detail"
        [ -n "$fix" ] && printf '      → %s\n' "$fix"
        return 0
    }

    id=""; level=""; title=""; detail=""; fix=""
    while IFS= read -r line; do
        case "$line" in
            '@@')
                render_one
                id=""; level=""; title=""; detail=""; fix=""
                ;;
            id=*)     id="${line#id=}" ;;
            level=*)  level="${line#level=}" ;;
            title=*)  title="${line#title=}" ;;
            detail=*) detail="${line#detail=}" ;;
            fix=*)    fix="${line#fix=}" ;;
        esac
    done < "$OUT"
    render_one          # 最后一条
else
    cat "$OUT"
fi

rm -f "$OUT"
exit 0
