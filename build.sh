#!/usr/bin/env bash
# ============================================================================
# 构建可刷入的模块 zip
#   产物：dist/xiaomi-rearscreen-appcard-preset-v<version>.zip
#   zip 根目录即模块根（module.prop 在根）
#
#   ./build.sh          构建
#   ./build.sh --check  只做一致性校验，不打包（CI 与提交前用）
# ============================================================================
set -euo pipefail

cd "$(dirname "$0")"

VERSION=$(sed -n 's/^version=//p' module/module.prop)
VCODE=$(sed -n 's/^versionCode=//p' module/module.prop)
NAME="xiaomi-rearscreen-appcard-preset-v${VERSION}"
OUT="dist/${NAME}.zip"

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

fail() { echo "✗ $*" >&2; exit 1; }
step() { echo "· $*"; }

# ============================================================ 一致性校验
step "校验模块文件"

for f in module.prop lib.sh customize.sh inject.sh status.sh action.sh \
         logpack.sh fetch.sh clear-reareye.sh fix-perms.sh appcard.manifest appcard.catalog; do
    [ -f "module/$f" ] || fail "缺少 module/$f"
done
[ -f module/webroot/index.html ] || fail "缺少 module/webroot/index.html"
[ -f module/webroot/app.js ]     || fail "缺少 module/webroot/app.js"
[ -f module/webroot/style.css ]  || fail "缺少 module/webroot/style.css"
[ -f mirrors.txt ]               || fail "缺少 mirrors.txt"

# 所有 shell 脚本语法检查
for f in module/*.sh; do
    sh -n "$f" 2>/dev/null || fail "$f 语法错误"
done
step "  shell 语法 OK"

# manifest 必须非空，且每行是 <sha256> <size> <path>
MANIFEST_N=$(grep -c . module/appcard.manifest)
[ "$MANIFEST_N" -gt 0 ] || fail "appcard.manifest 是空的"
awk 'NF && NF != 3 { print "✗ appcard.manifest 第 " NR " 行字段数不是 3: " $0 > "/dev/stderr"; bad=1 } END { exit bad }' \
    module/appcard.manifest || fail "appcard.manifest 格式错误"
step "  资源清单 $MANIFEST_N 个文件，格式正确"

# 卡片目录里的资源路径必须都在 manifest 里
python3 - <<'PY' || exit 1
import sys

man = set()
for line in open('module/appcard.manifest'):
    p = line.split()
    if len(p) >= 3:
        man.add(p[2])

bad = []
cards = 0
for line in open('module/appcard.catalog'):
    line = line.strip()
    if not line or line.startswith('#'):
        continue
    parts = line.split('|')
    if len(parts) != 5:
        bad.append(f"字段数不对（应为 5）: {line}")
        continue
    cards += 1
    if parts[4] not in man:
        bad.append(f"资源路径不在 manifest 中: {parts[4]}")

if bad:
    for b in bad:
        print("✗ " + b, file=sys.stderr)
    sys.exit(1)

print(f"  卡片目录 {cards} 张，资源路径全部命中 manifest")
PY

# 版本号对齐
grep -q "^version=${VERSION}$" module/module.prop || fail "版本号解析异常"
step "  版本 v${VERSION} (versionCode ${VCODE})"

if [ "$CHECK_ONLY" = "1" ]; then
    echo
    echo "✓ 校验通过"
    exit 0
fi

# ============================================================ 打包
step "打包"

rm -rf build dist
mkdir -p build dist

cp -a module/. build/
cp mirrors.txt build/mirrors.txt

# 同一份 inject.sh 复制到三个阶段
for stage in post-fs-data service boot-completed; do
    cp module/inject.sh "build/${stage}.sh"
done

# 权限：脚本可执行，其余只读；webroot 交给管理器读
chmod 755 build/*.sh
chmod 644 build/module.prop build/appcard.manifest build/appcard.catalog build/mirrors.txt
chmod 644 build/webroot/* 2>/dev/null || true
chmod 755 build/webroot
chmod 755 build

python3 - "$OUT" <<'PY'
import sys, os, zipfile

out = sys.argv[1]
root = "build"

with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for dirpath, _, files in os.walk(root):
        for fn in sorted(files):
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, root)
            mode = 0o755 if fn.endswith(".sh") else 0o644
            info = zipfile.ZipInfo(rel, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = mode << 16
            with open(full, "rb") as f:
                z.writestr(info, f.read())
print(f"  {out}  ({os.path.getsize(out)} bytes)")
PY

echo
unzip -l "$OUT" | sed -n '1,40p'
echo
echo "版本: v${VERSION}"
echo "产物: $OUT"
