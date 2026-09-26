#!/system/bin/sh
# ============================================================================
# 开机执行：确保资源就绪 + 挂载预置卡目录（幂等）
#
# 三个阶段共用本脚本（构建时复制为 post-fs-data.sh / service.sh / boot-completed.sh）：
#   post-fs-data   — 最早，此时无网络，只做挂载
#   service        — 网络可用，资源缺失时在此补齐（非阻塞，不影响开机速度）
#   boot-completed — 兜底再试一次
#
# 为什么不依赖 root 方案自己挂载模块文件：
#   APatch 把「模块文件挂载」委托给 metamodule（/data/adb/metamodule）。实测很多
#   机器（包括本模块的开发机）没装 metamodule，于是模块的 system/ 目录根本不会被
#   挂载 —— 同机上 zygisk_thanox、reqable-magisk 的 system/ 文件在 /system 里都
#   看不到。而模块目录下的阶段脚本一定会被执行，所以在脚本里自行 bind mount，
#   APatch / KernelSU / Magisk 通吃。
# ============================================================================

MODDIR=${0%/*}
[ -d "$MODDIR/product/media/rearscreen" ] || MODDIR=/data/adb/modules/rearscreen_appcard_preset
[ -f "$MODDIR/lib.sh" ] || exit 1

. "$MODDIR/lib.sh"

STAGE=${0##*/}
SRC="$MODDIR/product/media/rearscreen"
DST=/system/media/rearscreen
MARK="$DST/appcard/default/rearScreen.json"
SRC_MARK="$SRC/appcard/default/rearScreen.json"

# ---------------------------------------------------------------- 1. 已生效就直接退出
# 脚本可能跑过多次（三个阶段 + 手动触发），幂等处理
if [ -e "$MARK" ]; then
    DST_INO=$(stat -c '%d:%i' "$MARK" 2>/dev/null)
    SRC_INO=$(stat -c '%d:%i' "$SRC_MARK" 2>/dev/null)
    if [ -n "$DST_INO" ] && [ "$DST_INO" = "$SRC_INO" ]; then
        # 挂载还在，但资源可能在上次开机后补齐过 —— bind mount 会直接看到新文件，无需重挂
        set -- $(assets_progress "$MODDIR/$MANIFEST_NAME" "$SRC")
        xlog "$STAGE" "已挂载（${1:-0}/${2:-0}），跳过"
        exit 0
    fi
    xlog "$STAGE" "检测到预设存在但 inode 不一致，准备重新挂载"
fi

# ---------------------------------------------------------------- 2. 资源不齐则补齐
# 判据**不能**只看「主文件在不在」。真机上就卡在这儿：rearScreen.json 在，
# 于是这段被整个跳过 —— 后端的 8 个资源永远补不回来、600 权限的文件一直没人管，
# 面板还显示「23/31，还差 8 个」，用户点了半天「立即补齐」也没用。
set -- $(assets_progress "$MODDIR/$MANIFEST_NAME" "$SRC")
READY=${1:-0}; TOTAL=${2:-0}
PERM_OUT=$(perm_issues "$MODDIR/$MANIFEST_NAME" "$SRC")
PERMBAD=${PERM_OUT%%|*}

# 2a. 权限：不需要网络，任何阶段都能修，而且这正是「文件都在却看不到卡片」的元凶
if [ "$PERMBAD" -gt 0 ]; then
    PERM_LEFT=$(fix_perms "$SRC")
    xlog "$STAGE" "修正资源权限：$PERMBAD 个条目应用读不到，修正后剩 $PERM_LEFT"
fi

# 2b. 缺文件才需要联网
if [ ! -f "$SRC_MARK" ] || [ "$READY" -lt "$TOTAL" ]; then
    if [ "$STAGE" = "post-fs-data.sh" ]; then
        if [ ! -f "$SRC_MARK" ]; then
            # 主文件都没有，挂也没意义；此阶段确定无网络，别浪费开机时间
            xlog "$STAGE" "主文件缺失；post-fs-data 无网络，交给 service 阶段"
            exit 0
        fi
        xlog "$STAGE" "资源不全（$READY/$TOTAL），先挂上，service 阶段再补"
    else
        BUDGET=$INSTALL_BUDGET
        [ "$STAGE" = "boot-completed.sh" ] && BUDGET=0      # 最后一班车，不限时

        xlog "$STAGE" "资源不全（$READY/$TOTAL），开始补齐（预算 ${BUDGET}s）"
        refresh_mirrors "$MODDIR/mirrors.txt" >> "$LOGFILE" 2>&1

        if fetch_assets "$MODDIR/$MANIFEST_NAME" "$SRC" "$MODDIR/mirrors.txt" "$FETCH_JOBS" "$BUDGET" >> "$LOGFILE" 2>&1; then
            xlog "$STAGE" "资源补齐完成"
        else
            set -- $(assets_progress "$MODDIR/$MANIFEST_NAME" "$SRC")
            xlog "$STAGE" "资源仍未齐（${1:-0}/${2:-0}），下次开机再试"
            # 只要主文件到位就先挂，卡片少几张也好过完全没有
            [ -f "$SRC_MARK" ] || exit 1
        fi
    fi
fi

# ---------------------------------------------------------------- 3. 等目标路径就绪
i=0
while [ "$i" -lt 60 ]; do
    [ -d "$DST" ] && break
    sleep 1
    i=$((i + 1))
done
if [ ! -d "$DST" ]; then
    xlog "$STAGE" "目标路径 $DST 未就绪，放弃"
    exit 1
fi

# ---------------------------------------------------------------- 4. 修正 SELinux 上下文
# 上下文不对的话 untrusted_app 读不到文件，表现出来就是「挂上了但卡片不出现」
chcon -R u:object_r:system_file:s0 "$SRC" 2>>"$LOGFILE"

# ---------------------------------------------------------------- 5. bind mount
mount --bind "$SRC" "$DST" 2>>"$LOGFILE"

if [ -e "$MARK" ]; then
    DST_INO=$(stat -c '%d:%i' "$MARK" 2>/dev/null)
    SRC_INO=$(stat -c '%d:%i' "$SRC_MARK" 2>/dev/null)
    if [ -n "$DST_INO" ] && [ "$DST_INO" = "$SRC_INO" ]; then
        xlog "$STAGE" "挂载成功（inode $DST_INO）"
        exit 0
    fi
    xlog "$STAGE" "挂载后 inode 仍不一致（模块 $SRC_INO / 系统 $DST_INO）"
    exit 1
fi

xlog "$STAGE" "挂载失败：$MARK 不存在"
exit 1
