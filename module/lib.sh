#!/system/bin/sh
# ============================================================================
# 共享函数库：下载 / 校验 / 落盘
# 被 customize.sh（安装时）与 inject.sh（开机兜底）source
#
# 下载策略（按序回退）：
#   1. 直连 GitHub（海外用户 / 有代理的用户首选，也避免与上游脱轨）
#   2. 镜像列表（国内可达的加速站）
#   3. 镜像列表本身可远程更新，见 refresh_mirrors()
# 每个文件都校验 SHA-256；全部通过才算成功。
# ============================================================================

# ---- 上游资源（不随仓库分发，运行时拉取）----------------------------------
UPSTREAM_REPO="NekoStash/REAREye-Preset-Resources"
UPSTREAM_COMMIT="633d834c9af31ff9ff27945f74fac44dbb4f691a"
UPSTREAM_PATH="preset/rear_preset"
RAW_BASE="https://raw.githubusercontent.com/${UPSTREAM_REPO}/${UPSTREAM_COMMIT}/${UPSTREAM_PATH}"

MANIFEST_NAME="appcard.manifest"

# ---- 镜像列表：可远程更新 --------------------------------------------------
# 优先用缓存的远程列表，其次用模块内置的 mirrors.txt
SELF_REPO="zilewang7/xiaomi-rearscreen-appcard-preset"
MIRROR_LIST_URL="https://raw.githubusercontent.com/${SELF_REPO}/main/mirrors.txt"
MIRROR_CACHE=/data/local/tmp/rearscreen_appcard_mirrors.txt
MIRROR_CACHE_MAX_AGE=604800   # 秒，7 天

log() { echo "[appcard] $*"; }

# ---------------------------------------------------------------- 单次抓取
_fetch() {  # $1=url $2=out
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 --retry 1 -o "$2" "$1" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 30 -O "$2" "$1" 2>/dev/null
    elif command -v busybox >/dev/null 2>&1; then
        busybox wget -q -T 30 -O "$2" "$1" 2>/dev/null
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

# ---------------------------------------------------------------- 列表刷新
# 用「直连 + 内置列表」去尝试拉取最新的 mirrors.txt，成功则缓存
refresh_mirrors() {  # $1=模块内置 mirrors.txt 路径
    bundled="$1"

    if [ -f "$MIRROR_CACHE" ]; then
        age=$(( $(date +%s) - $(date -r "$MIRROR_CACHE" +%s 2>/dev/null || echo 0) ))
        [ "$age" -lt "$MIRROR_CACHE_MAX_AGE" ] && return 0
    fi

    for url in "$MIRROR_LIST_URL" $(for t in $(_mirror_lines "$bundled"); do _expand "$t" "" ; done 2>/dev/null); do
        [ -n "$url" ] || continue
        # 列表文件自身用 _expand 后可能带路径占位为空的尾巴，做个兜底
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
# $1=相对路径  $2=输出  $3=模块内置 mirrors.txt
download() {
    rel="$1"; out="$2"; bundled="$3"

    # 1) 直连
    if _fetch "${RAW_BASE}/${rel}" "$out"; then
        return 0
    fi

    # 2) 镜像（优先远程列表，其次内置）
    list="$bundled"
    [ -f "$MIRROR_CACHE" ] && list="$MIRROR_CACHE"

    for tpl in $(_mirror_lines "$list"); do
        url=$(_expand "$tpl" "$rel")
        if _fetch "$url" "$out"; then
            log "  已通过镜像获取：${url%%/https*}"
            return 0
        fi
    done

    return 1
}

# ---------------------------------------------------------------- 拉取全部
# $1=清单  $2=目标根目录（其下含 appcard/…）  $3=内置 mirrors.txt
fetch_assets() {
    manifest="$1"; dest="$2"; bundled="$3"

    [ -f "$manifest" ] || { log "错误：找不到清单 $manifest"; return 1; }

    total=$(grep -c . "$manifest")
    idx=0; failed=0

    while read -r sha size path; do
        [ -n "$path" ] || continue
        idx=$((idx + 1))
        out="$dest/$path"

        # 已存在且校验通过 → 跳过（支持断点续传 / 重试）
        if [ -f "$out" ] && [ "$(_sha256 "$out")" = "$sha" ]; then
            continue
        fi

        mkdir -p "$(dirname "$out")"
        log "  [$idx/$total] $path"
        if ! download "$path" "$out" "$bundled"; then
            log "    ✗ 所有源均不可达"
            failed=$((failed + 1))
            continue
        fi

        if [ "$(_sha256 "$out")" != "$sha" ]; then
            log "    ✗ SHA-256 校验失败，已删除"
            rm -f "$out"
            failed=$((failed + 1))
        fi
    done < "$manifest"

    [ "$failed" -gt 0 ] && { log "$failed 个文件失败"; return 1; }
    log "资源就绪：$total 个文件全部校验通过"
    return 0
}
