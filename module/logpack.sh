#!/system/bin/sh
# ============================================================================
# 日志导出：把诊断需要的东西**合并成一个 txt**，用户直接发给开发者就行
#
# 为什么是单个 txt 而不是 zip：
#   用户要的是「把文件发给你」，不是「打包」。txt 不用装解压软件、能直接
#   粘贴到论坛、手机上也容易预览。诊断所需的信息量本来就只有几 KB。
#
# 用法：logpack.sh
# 输出：最后一行是生成的 txt 绝对路径
#
# 隐私：不含账号、不含手机号、不含已安装应用清单，只有排障必需项
# ============================================================================

MODDIR=${0%/*}
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/rearscreen_appcard_preset

. "$MODDIR/lib.sh"

STAMP=$(date '+%m%d-%H%M')
OUTDIR=/sdcard/Download
[ -d "$OUTDIR" ] && [ -w "$OUTDIR" ] || OUTDIR=/data/local/tmp
REPORT="$OUTDIR/appcard-$STAMP.txt"

SRC="$MODDIR/product/media/rearscreen"
MARK=/system/media/rearscreen/appcard/default/rearScreen.json

sec() { printf '\n================ %s ================\n' "$1"; }

{
    echo "背屏应用卡中心 诊断日志"
    echo "生成时间：$(date '+%F %T %Z')"
    echo "模块版本：v$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null)"
    echo "（这份文件不含账号信息，可直接发到社区或发给开发者）"

    sec "1. 自检报告"
    sh "$MODDIR/status.sh" --text 2>&1

    sec "2. 自检原始数据"
    sh "$MODDIR/status.sh" 2>&1

    sec "3. 设备与系统"
    for p in ro.product.model ro.product.device ro.build.version.release \
             ro.build.version.sdk ro.mi.os.version.name ro.build.version.incremental \
             ro.miui.ui.version.name ro.build.type ro.boot.verifiedbootstate \
             persist.sys.timezone; do
        echo "$p = $(getprop $p)"
    done
    echo "SELinux = $(getenforce 2>/dev/null)"
    echo "开机时长 = $(cut -d. -f1 /proc/uptime 2>/dev/null) 秒"

    sec "4. 模块文件与资源"
    set -- $(assets_progress "$MODDIR/$MANIFEST_NAME" "$SRC")
    echo "资源进度：${1:-0} / ${2:-0}"
    echo
    echo "-- 缺失或校验失败的文件 --"
    miss=0
    while read -r sha size path; do
        [ -n "$path" ] || continue
        f="$SRC/$path"
        if [ ! -f "$f" ]; then echo "缺失  $path"; miss=$((miss+1))
        elif [ "$(_sha256 "$f")" != "$sha" ]; then echo "损坏  $path"; miss=$((miss+1))
        fi
    done < "$MODDIR/$MANIFEST_NAME"
    [ "$miss" -eq 0 ] && echo "（无，31 个文件都在）"
    echo
    echo "-- 模块根目录 --"
    ls -la "$MODDIR" 2>&1
    echo
    echo "-- 预设目录 --"
    ls -la "$SRC/appcard/default/" 2>&1

    sec "5. 挂载与 SELinux"
    echo "-- rearscreen 相关挂载 --"
    mount 2>/dev/null | grep rearscreen || echo "（没有 rearscreen 挂载！）"
    echo
    echo "-- inode 比对（一致才说明挂的是本模块的文件）--"
    echo "模块内：$(stat -c '%d:%i  大小 %s' "$SRC/appcard/default/rearScreen.json" 2>&1)"
    echo "系统侧：$(stat -c '%d:%i  大小 %s' "$MARK" 2>&1)"
    echo
    echo "-- SELinux 上下文 --"
    ls -Zd "$MARK" 2>&1
    echo
    echo "-- /system/media 软链指向 --"
    ls -ld /system/media 2>&1
    echo
    echo "-- metamodule（决定模块文件是否会被自动挂载）--"
    ls -d /data/adb/metamodule 2>&1 || echo "未安装"

    sec "6. Root 方案与模块环境"
    echo "-- 模块列表 --"
    ls /data/adb/modules/ 2>&1
    echo
    echo "-- 其它模块是否也占用 system/media --"
    same=0
    for d in /data/adb/modules/*/; do
        if [ -d "$d/system/media" ]; then echo "  $(basename "$d") 也有 system/media/"; same=1; fi
    done
    [ "$same" -eq 0 ] && echo "（无）"
    echo
    echo "-- 本模块的 webroot --"
    ls -la "$MODDIR/webroot/" 2>&1

    sec "7. 开机与操作日志"
    cat "$LOGFILE" 2>/dev/null || echo "（无日志文件，说明阶段脚本没执行过）"

    sec "8. 预设卡片清单（前 120 行）"
    head -c 4000 "$MARK" 2>/dev/null || echo "（读不到预设）"

    echo
    echo "================ 结束 ================"
} > "$REPORT" 2>&1

SIZE=$(stat -c '%s' "$REPORT" 2>/dev/null || echo 0)

if [ -f "$REPORT" ] && [ "$SIZE" -gt 100 ] 2>/dev/null; then
    # 最后一行必须是路径 —— WebUI 靠它拿给用户看
    echo "$REPORT"
else
    echo "FAILED"
fi
exit 0
