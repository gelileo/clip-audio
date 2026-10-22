#!/usr/bin/env bash
# Fetch embedded Python runtime + vendor pure-Python deps. Outputs gitignored.
set -euo pipefail
PY_VER="3.14"; PY_BUILD="b12"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SUPPORT="$HERE/Support"
TARBALL="Python-${PY_VER}-iOS-support.${PY_BUILD}.tar.gz"
URL="https://github.com/beeware/Python-Apple-support/releases/download/${PY_VER}-${PY_BUILD}/${TARBALL}"

mkdir -p "$SUPPORT"
if [ ! -d "$SUPPORT/Python.xcframework" ]; then
  echo "==> downloading $TARBALL"
  curl -fL "$URL" -o "$SUPPORT/$TARBALL"
  tar xzf "$SUPPORT/$TARBALL" -C "$SUPPORT"
  rm -f "$SUPPORT/$TARBALL"
fi
echo "==> Python.xcframework ready ($(cat "$SUPPORT/VERSIONS" | head -1))"

rm -rf "$HERE/app_packages"; mkdir -p "$HERE/app_packages"
python3 -m pip install --quiet --upgrade --no-deps --target "$HERE/app_packages" yt-dlp yt-dlp-ejs certifi
find "$HERE/app_packages" \( -name '__pycache__' -o -name '*.dist-info' \) -prune -exec rm -rf {} + 2>/dev/null || true
QJS_VER="0.17.0"
if [ ! -d "$HERE/vendor/quickjs" ]; then
  echo "==> downloading quickjs-ng v$QJS_VER"
  mkdir -p "$HERE/vendor" /tmp/qjs-dl
  curl -fsSL -o /tmp/qjs-dl/qjs.tar.gz \
    "https://github.com/quickjs-ng/quickjs/archive/refs/tags/v${QJS_VER}.tar.gz"
  tar xzf /tmp/qjs-dl/qjs.tar.gz -C /tmp/qjs-dl
  mv /tmp/qjs-dl/quickjs-* "$HERE/vendor/quickjs"
  rm -rf /tmp/qjs-dl
fi
echo "==> quickjs-ng ready"

echo "==> vendored app_packages: $(du -sh "$HERE/app_packages" | cut -f1)"
