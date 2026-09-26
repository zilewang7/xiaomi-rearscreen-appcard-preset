#!/system/bin/sh
# ============================================================================
# 共享函数库：下载 / 校验 / 落盘 / 进度
#
# 被三处 source：
#   customize.sh  安装时（有网络，尽量下完；但有时间预算，超时就收工不阻塞安装）
#   inject.sh     开机 service / boot-completed 阶段（后台补齐）
#   status.sh     诊断页复用常量与校验函数
#
# 下载策略（按序回退）：
#   1. 直连 GitHub    —— 海外用户 / 有代理的用户首选，也避免与上游脱轨
#   2. 镜像列表       —— 国内可达的加速站
#   3. 列表本身可远程更新，见 refresh_mirrors()
#
# 健壮性要点（对应社区反馈「安装卡住」）：
#   · 每个请求都有 --max-time 上限，绝不无限等待
#   · 整体有时间预算，超预算立即收工，剩余交给开机后台补，绝不阻塞安装
#   · 多线程并发（延迟敏感场景快数倍）
#   · 连续失败且零成功 → 判定网络不可达，立刻放弃，不让无网用户干等
#   · 每个文件都校验 SHA-256，校验不过就删掉换源重下
# ============================================================================

# ---- 上游资源（不随仓库分发，运行时拉取）----------------------------------
UPSTREAM_REPO="NekoStash/REAREye-Preset-Resources"
UPSTREAM_COMMIT="633d834c9af31ff9ff27945f74fac44dbb4f691a"
UPSTREAM_PATH="preset/rear_preset"
RAW_BASE="https://raw.githubusercontent.com/${UPSTREAM_REPO}/${UPSTREAM_COMMIT}/${UPSTREAM_PATH}"

MANIFEST_NAME="appcard.manifest"
CATALOG_NAME="appcard.catalog"

# ---- 镜像列表：可远程更新 --------------------------------------------------
SELF_REPO="zilewang7/xiaomi-rearscreen-appcard-preset"
MIRROR_LIST_URL="https://raw.githubusercontent.com/${SELF_REPO}/main/mirrors.txt"
MIRROR_CACHE=/data/local/tmp/rearscreen_appcard_mirrors.txt
MIRROR_CACHE_MAX_AGE=604800   # 秒，7 天

# ---- umask：写出来的文件必须「应用也读得到」 --------------------------------
# 模块目录会被 bind mount 到 /product/media/rearscreen，背屏应用是以**自己的 uid**
# （u0_a140）去读的，不是 root。而 curl -o 写文件是 0666 & ~umask，
# mkdir -p 是 0777 & ~umask —— 只要执行环境带了 umask 077，就会写出
# 0600 的文件和 0700 的目录，应用直接 EACCES。
#
# 管理器的 WebUI exec 和部分开机脚本确实带 077（真机上踩过：资源「23/31 就绪」，
# 面板全绿，卡片一张不显示；同一批文件里 23:02 下的那几个是 0644，
# 23:06 二次补齐下的那几个是 0600 —— 两个上下文 umask 不一样）。
# 这里显式钉死，另外 fix_perms() 会把整棵树的权限摆正，双保险。
umask 022

# ---- mount namespace 修正 ---------------------------------------------------
# 管理器 WebUI 里的 exec 是「管理器的子进程」，因此继承了 Android 给应用准备的
# 隔离 mount namespace。在那个视图里 /data/data 只剩几个条目（真机实测只有
# com.google.android.gms / com.xiaomi.aiservice / 管理器自己，而正常是 937 个），
# 其它应用的数据目录**看起来根本不存在**。
#
# 后果很隐蔽：任何「去别的应用数据目录看一眼」的检查都会静默变成「没有」——
# 包括 REAREye 冲突检测。状态页于是安静地报绿，用户却看不到卡片。
# 这正是社区反馈「每一项都是绿的，但没卡片」的成因之一。
#
# 修正办法：发现视图被隔离就带 init 的 mount namespace 重跑自己。
# 先验证 nsenter 真的有效（不同设备/内核对 -t 1 的处理不一样），再 exec，
# 免得把脚本直接跑死。
ns_reexec() {  # 用法：ns_reexec "$@"，放在脚本 source lib.sh 之后
    [ -n "$APPCARD_NS_FIXED" ] && return 0
    n=$(ls /data/data 2>/dev/null | wc -l)
    [ "${n:-0}" -ge 100 ] && return 0          # 视图正常，无事发生
    command -v nsenter >/dev/null 2>&1 || return 0

    n2=$(nsenter -t 1 -m -- ls /data/data 2>/dev/null | wc -l)
    [ "${n2:-0}" -ge 100 ] || return 0         # nsenter 也救不了，就算了

    APPCARD_NS_FIXED=1
    export APPCARD_NS_FIXED
    exec nsenter -t 1 -m -- "$0" "$@"
}

# 视图是不是被隔离过（状态页可以据此提示用户）
ns_was_isolated() { [ -n "$APPCARD_NS_FIXED" ] && echo 1 || echo 0; }

# ---- 网络预算 --------------------------------------------------------------
FETCH_CONNECT_TIMEOUT=6      # 单次连接超时（秒）
FETCH_MAX_TIME=25            # 单文件总时长上限（秒），超时立即换下一个源
FETCH_JOBS=4                 # 并发数
INSTALL_BUDGET=100           # 安装阶段总预算（秒），超了留给开机后台补

# 全局截止时刻（epoch 秒）；0 表示不限。由 fetch_assets 设置，子 shell 继承。
_DEADLINE=0

_has_budget() {
    [ "$_DEADLINE" -eq 0 ] && return 0
    [ "$(date +%s)" -lt "$_DEADLINE" ]
}

log() { echo "[appcard] $*"; }

# ---------------------------------------------------------------- 活动日志
LOGFILE=/data/local/tmp/rearscreen_appcard_preset.log

# 开机早期系统时钟还没同步，date 会给出 1970 年，那种时间戳没法读。
# 这时改用 uptime，至少能看出「开机第几秒发生的事」。
_now() {
    case "$(date +%Y 2>/dev/null)" in
        19*|200*|201*|202[0-4])
            up=$(cut -d. -f1 /proc/uptime 2>/dev/null)
            echo "开机+${up:-?}s" ;;
        *)
            date '+%F %T' 2>/dev/null ;;
    esac
}

xlog() {  # $1=来源 $2=消息
    echo "[$(_now)] $1: $2" >> "$LOGFILE" 2>/dev/null
}

# ---------------------------------------------------------------- 单次抓取
_fetch() {  # $1=url $2=out
    _has_budget || return 1
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout "$FETCH_CONNECT_TIMEOUT" --max-time "$FETCH_MAX_TIME" \
             -o "$2" "$1" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T "$FETCH_MAX_TIME" -O "$2" "$1" 2>/dev/null
    elif command -v busybox >/dev/null 2>&1; then
        busybox wget -q -T "$FETCH_MAX_TIME" -O "$2" "$1" 2>/dev/null
    else
        return 1
    fi
    [ -s "$2" ]
}

_sha256() {  # $1=file
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    elif command -v busybox  >/dev/null 2>&1; then busybox sha256sum "$1" | cut -d' ' -f1
    elif command -v toybox   >/dev/null 2>&1; then toybox sha256sum "$1" | cut -d' ' -f1
    else echo ""; fi
}

# ---------------------------------------------------------------- 模板展开
_expand() {  # $1=模板 $2=相对路径
    printf '%s' "$1" \
        | sed -e "s|{repo}|${UPSTREAM_REPO}|g" \
              -e "s|{commit}|${UPSTREAM_COMMIT}|g" \
              -e "s|{path}|$2|g" \
              -e "s|{url}|${RAW_BASE}/$2|g"
}

_mirror_lines() {  # $1=列表文件
    [ -f "$1" ] || return 0
    grep -v '^[[:space:]]*#' "$1" 2>/dev/null | grep -v '^[[:space:]]*$'
}

# 当前生效的镜像列表：优先远程缓存，其次模块内置
_mirror_list() {  # $1=内置 mirrors.txt
    if [ -f "$MIRROR_CACHE" ]; then echo "$MIRROR_CACHE"; else echo "$1"; fi
}

# ---------------------------------------------------------------- 列表刷新
refresh_mirrors() {  # $1=模块内置 mirrors.txt 路径
    bundled="$1"

    if [ -f "$MIRROR_CACHE" ]; then
        age=$(( $(date +%s) - $(date -r "$MIRROR_CACHE" +%s 2>/dev/null || echo 0) ))
        [ "$age" -lt "$MIRROR_CACHE_MAX_AGE" ] && return 0
    fi

    for url in "$MIRROR_LIST_URL" $(for t in $(_mirror_lines "$bundled"); do _expand "$t" ""; done 2>/dev/null); do
        [ -n "$url" ] || continue
        case "$url" in *'{'*) continue ;; esac
        if _fetch "$url" "$MIRROR_CACHE.tmp" && grep -q '{url}' "$MIRROR_CACHE.tmp" 2>/dev/null; then
            mv "$MIRROR_CACHE.tmp" "$MIRROR_CACHE"
            log "镜像列表已更新（来自 $url）"
            return 0
        fi
    done
    rm -f "$MIRROR_CACHE.tmp"
    return 1
}

# ---------------------------------------------------------------- 带回退下载
# 直连 → 各镜像，成功 0 / 失败 1
download() {  # $1=相对路径 $2=输出 $3=模块内置 mirrors.txt
    rel="$1"; out="$2"; bundled="$3"

    if _fetch "${RAW_BASE}/${rel}" "$out"; then
        return 0
    fi

    for tpl in $(_mirror_lines "$(_mirror_list "$bundled")"); do
        url=$(_expand "$tpl" "$rel")
        case "$url" in *'{'*) continue ;; esac
        if _fetch "$url" "$out"; then
            log "  已通过镜像获取：${url%%/https*}"
            return 0
        fi
    done

    return 1
}

# ---------------------------------------------------------------- 单文件任务
# 下载 + 校验，失败换源重试一轮；成功 0
_fetch_one() {  # $1=sha $2=rel $3=dest $4=bundled
    sha="$1"; rel="$2"; dest="$3"; bundled="$4"
    out="$dest/$rel"

    [ -f "$out" ] && [ "$(_sha256 "$out")" = "$sha" ] && return 0

    mkdir -p "$(dirname "$out")"

    attempt=0
    while [ "$attempt" -lt 2 ]; do
        attempt=$((attempt + 1))
        if download "$rel" "$out" "$bundled"; then
            if [ "$(_sha256 "$out")" = "$sha" ]; then
                # 显式摆正权限：不能指望执行环境的 umask 是 022（见文件顶部说明）
                chmod 0644 "$out" 2>/dev/null
                _chmod_up 0755 "$dest" "$(dirname "$out")"
                return 0
            fi
            log "    ✗ $rel 校验不符，换源重试"
        fi
        rm -f "$out"
    done
    return 1
}

# $1=权限 $2=停止目录 $3=起点目录 → 从起点一路往上 chmod，到停止目录为止
# （mkdir -p 建出来的中间目录也可能是 0700，只 chmod 文件本身不够）
_chmod_up() {
    perm="$1"; stop="$2"; d="$3"
    while [ -n "$d" ] && [ "$d" != "/" ] && [ "$d" != "." ]; do
        chmod "$perm" "$d" 2>/dev/null
        [ "$d" = "$stop" ] && break
        nd=$(dirname "$d")
        [ "$nd" = "$d" ] && break
        d="$nd"
    done
}

# ---------------------------------------------------------------- 拉取全部
# $1=清单 $2=目标根 $3=内置 mirrors.txt $4=并发数 $5=时间预算秒(0=不限)
# 全部就绪返回 0；有缺失返回 1（不算致命，开机后台会补）
fetch_assets() {
    manifest="$1"; dest="$2"; bundled="$3"
    jobs="${4:-$FETCH_JOBS}"
    budget="${5:-0}"

    [ -f "$manifest" ] || { log "错误：找不到清单 $manifest"; return 1; }

    total=$(grep -c . "$manifest")

    case "$budget" in ''|*[!0-9]*) budget=0 ;; esac
    if [ "$budget" -gt 0 ]; then
        _DEADLINE=$(( $(date +%s) + budget ))
    else
        _DEADLINE=0
    fi

    # 先数还差几个，都齐了就直接返回
    missing=0
    while read -r sha size path; do
        [ -n "$path" ] || continue
        if [ ! -f "$dest/$path" ] || [ "$(_sha256 "$dest/$path")" != "$sha" ]; then
            missing=$((missing + 1))
        fi
    done < "$manifest"

    if [ "$missing" -eq 0 ]; then
        log "资源就绪：$total/$total 个文件全部校验通过"
        return 0
    fi

    log "需要下载 $missing/$total 个文件（并发 $jobs）"

    work="/data/local/tmp/appcard_fetch_$$"
    rm -rf "$work"; mkdir -p "$work"
    # 轮流分片，避免某片全是难下的文件
    awk -v n="$jobs" -v d="$work" 'NF { print > (d "/chunk_" (NR % n)) }' "$manifest"

    j=0
    while [ "$j" -lt "$jobs" ]; do
        if [ -f "$work/chunk_$j" ]; then
            (
                ok=0; fail=0; consec=0; dead=0
                while read -r sha size path; do
                    [ -n "$path" ] || continue
                    if ! _has_budget; then dead=2; break; fi
                    if _fetch_one "$sha" "$path" "$dest" "$bundled"; then
                        ok=$((ok + 1)); consec=0
                    else
                        fail=$((fail + 1)); consec=$((consec + 1))
                        [ "$ok" -eq 0 ] && [ "$consec" -ge 3 ] && { dead=1; break; }
                    fi
                done < "$work/chunk_$j"
                echo "$ok $fail $dead" > "$work/w_$j.stat"
            ) &
        fi
        j=$((j + 1))
    done
    wait

    ok=0; dead=0
    j=0
    while [ "$j" -lt "$jobs" ]; do
        if [ -f "$work/w_$j.stat" ]; then
            read -r a b c < "$work/w_$j.stat"
            ok=$((ok + ${a:-0}))
            [ "${c:-0}" = "1" ] && dead=1
        fi
        j=$((j + 1))
    done

    if [ "$dead" = "1" ] && [ "$ok" -eq 0 ]; then
        log "网络不可达：直连与全部镜像都失败，已提前退出"
        log "可开代理后重启设备，或在管理器点「操作」重试"
        rm -rf "$work"
        return 1
    fi

    # 最终逐文件复核
    ready=0; bad=0
    while read -r sha size path; do
        [ -n "$path" ] || continue
        if [ -f "$dest/$path" ] && [ "$(_sha256 "$dest/$path")" = "$sha" ]; then
            ready=$((ready + 1))
        else
            bad=$((bad + 1))
        fi
    done < "$manifest"

    rm -rf "$work"

    # 整棵树权限摆正：下完之后统一来一次，比在每个下载点打补丁可靠
    fix_perms "$dest" >/dev/null

    if [ "$bad" -eq 0 ]; then
        log "资源就绪：$ready/$total 个文件全部校验通过"
        return 0
    fi

    if ! _has_budget; then
        log "时间预算用尽：已就绪 $ready/$total，其余重启后自动补齐"
    else
        log "已就绪 $ready/$total，$bad 个暂未取到，重启后自动补齐"
    fi
    return 1
}

# ---------------------------------------------------------------- 进度查询
# 输出「已就绪 总数」，供 status.sh 算进度
assets_progress() {  # $1=清单 $2=资源根目录
    manifest="$1"; dest="$2"
    total=0; ready=0
    [ -f "$manifest" ] || { echo "0 0"; return; }
    while read -r sha size path; do
        [ -n "$path" ] || continue
        total=$((total + 1))
        if [ -f "$dest/$path" ] && [ "$(_sha256 "$dest/$path")" = "$sha" ]; then
            ready=$((ready + 1))
        fi
    done < "$manifest"
    echo "$ready $total"
}

# ---------------------------------------------------------------- 权限
# assets_progress 是拿 root 去读的，所以永远读得到 0600 的文件 —— 它只能回答
# 「文件在不在」，回答不了「应用读不读得到」。这是两个不同的问题，
# 而后者才是卡片出不出现的原因。下面这几个函数就是补上后者。

_mode() { stat -c %a "$1" 2>/dev/null || echo '?'; }

# 取权限的末位（others 那一位），判断「别人」能不能读 / 能不能进
_o_readable() { case "$(_mode "$1")" in *[4567]) return 0 ;; *) return 1 ;; esac; }
_o_xable()    { case "$(_mode "$1")" in *[1357]) return 0 ;; *) return 1 ;; esac; }

# $1=清单 $2=资源根 → 输出 "<个数>|<前几条明细>"
# 明细只能这样一起带出来：调用方必须用 $( )，而那是个子 shell，
# 在里面赋值外面拿不到（第一版就踩了这个，明细永远是空的）。
# 只沿着 $dest 以下的路径检查 —— 再往上（/data/adb 之类）应用本来就不走，
# 查了反而会天天误报。
perm_issues() {
    manifest="$1"; dest="$2"
    n=0; detail=""
    [ -f "$manifest" ] || { echo "0|"; return; }

    while read -r sha size path; do
        [ -n "$path" ] || continue
        f="$dest/$path"
        [ -f "$f" ] || continue

        why=""
        _o_readable "$f" || why="文件 $(_mode "$f")"

        # 路径上每一层目录都要能「进得去」，否则文件权限对也没用
        if [ -z "$why" ]; then
            _o_xable "$dest" || why="目录 $(_mode "$dest")"
        fi
        if [ -z "$why" ]; then
            reldir=$(dirname "$path")
            if [ "$reldir" != "." ]; then
                cur="$dest"
                for seg in $(printf '%s' "$reldir" | tr '/' ' '); do
                    cur="$cur/$seg"
                    if [ -d "$cur" ] && ! _o_xable "$cur"; then
                        why="目录 $(_mode "$cur")"
                        break
                    fi
                done
            fi
        fi

        if [ -n "$why" ]; then
            n=$((n + 1))
            [ "$n" -le 3 ] && detail="$detail${path}（${why}） "
        fi
    done < "$manifest"

    echo "$n|$detail"
}

# $1=资源根 → 把整棵树摆正成「目录 755 / 文件 644」，返回修正后仍不对的数
# 用逐条 chmod 而不是 chmod -R a+rX：X 的语义在 toybox / busybox / GNU 上一致，
# 但这里要的就是固定 755/644（和 ROM 原文件的权限一致），写死更可控。
# 这个树里只有 json / png，没有可执行文件，不会被误伤。
fix_perms() {
    root="$1"
    [ -d "$root" ] || { echo 0; return 0; }
    chmod 0755 "$root" 2>/dev/null
    command -v find >/dev/null 2>&1 || { count_unreadable "$root"; return 0; }
    find "$root" 2>/dev/null | while IFS= read -r p; do
        if [ -d "$p" ]; then chmod 0755 "$p" 2>/dev/null
        else chmod 0644 "$p" 2>/dev/null
        fi
    done
    count_unreadable "$root"
}

# $1=资源根 → 全树数「App 读不到的文件 / 进不去的目录」，用来验证修复结果。
# 用 _o_readable/_o_xable 逐条判断，不依赖 find 的 -perm 谓词（各实现差异较大）。
count_unreadable() {
    root="$1"
    [ -d "$root" ] || { echo 0; return 0; }
    command -v find >/dev/null 2>&1 || { echo 0; return 0; }
    n=0
    for p in $(find "$root" 2>/dev/null); do
        if [ -d "$p" ]; then
            _o_xable "$p"    || n=$((n + 1))
        elif [ -f "$p" ]; then
            _o_readable "$p" || n=$((n + 1))
        fi
    done
    echo "$n"
}
