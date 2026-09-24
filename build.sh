#!/usr/bin/env bash
# ============================================================================
# 构建可刷入的模块 zip
#   产物：dist/xiaomi-rearscreen-appcard-preset-v<version>.zip
#   zip 根目录即模块根（module.prop 在根）
# ============================================================================
set -euo pipefail

cd "$(dirname "$0")"

VERSION=$(grep '^version=' module/module.prop | cut -d= -f2)
NAME="xiaomi-rearscreen-appcard-preset-v${VERSION}"
OUT="dist/${NAME}.zip"

rm -rf build dist
mkdir -p build dist

# ---- 模块内容 ----
cp -a module/. build/

# 同一份 inject.sh 复制到三个阶段
for stage in post-fs-data service boot-completed; do
    cp module/inject.sh "build/${stage}.sh"
done

chmod 755 build/*.sh
chmod 644 build/module.prop build/lib.sh build/appcard.manifest build/mirrors.txt 2>/dev/null || true
# mirrors.txt 同时放在模块根，供开机刷新用
cp mirrors.txt build/mirrors.txt

# ---- 打包（python 自带 zipfile，免 zip 依赖）----
python3 - "$OUT" <<'PY'
import sys, os, zipfile

out = sys.argv[1]
root = "build"

with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for dirpath, _, files in os.walk(root):
        for fn in sorted(files):
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, root)
            # 保持可执行位
            info = zipfile.ZipInfo.from_file(full, rel)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (0o755 if full.endswith(".sh") else 0o644) << 16
            with open(full, "rb") as f:
                z.writestr(info, f.read())
print(f"打包完成: {out}  ({os.path.getsize(out)} bytes)")
PY

unzip -l "$OUT" | tail -20
echo
echo "版本: v${VERSION}"
echo "产物: $OUT"
