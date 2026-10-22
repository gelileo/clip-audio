#!/bin/sh
set -e
source "$PROJECT_DIR/Support/Python.xcframework/build/utils.sh"
install_python Support/Python.xcframework app_packages app

# Trim. install_stdlib copies the FULL stdlib, including CPython's own
# test suite (~37MB). None of this is reachable at runtime.
STDLIB="$CODESIGNING_FOLDER_PATH/python/lib/python3.14"
for junk in test idlelib ensurepip pydoc_data turtledemo tkinter lib2to3 \
            distutils venv curses dbm sqlite3/test; do
  rm -rf "$STDLIB/$junk"
done
find "$STDLIB" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
find "$CODESIGNING_FOLDER_PATH/app_packages" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
echo "trimmed bundle: $(du -sh "$CODESIGNING_FOLDER_PATH" | cut -f1)"

# Precompile to bytecode. Python-Apple-support ships source only, the
# bundle is read-only and write_bytecode=0, so without this every cold
# start reparses ~20MB of .py — 16.4s on an A16 (M1 device run).
# unchecked-hash: never stat/validate, the bundle cannot change.
# Target version is whatever install_stdlib just laid down.
STDLIB="$(ls -1d "$CODESIGNING_FOLDER_PATH"/python/lib/python3.* 2>/dev/null | head -1)"
TARGET_VER="$(basename "$STDLIB" | sed 's/^python//')"
# Xcode build phases get a restricted PATH where python3 is macOS's
# system 3.9. Compiling with it would emit wrong-magic .pyc, and we
# delete the sources — so find a matching interpreter or fail loudly.
PYBIN=""
for C in "$CLIPAUDIO_HOST_PYTHON" \
         "/opt/homebrew/bin/python$TARGET_VER" \
         "/usr/local/bin/python$TARGET_VER" \
         "/opt/homebrew/bin/python3" \
         "$(command -v "python$TARGET_VER" 2>/dev/null)" \
         "$(command -v python3 2>/dev/null)"; do
  [ -n "$C" ] && [ -x "$C" ] || continue
  V="$("$C" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null)" || continue
  if [ "$V" = "$TARGET_VER" ]; then PYBIN="$C"; break; fi
done
if [ -z "$PYBIN" ]; then
  echo "error: no host python $TARGET_VER found for bytecode precompilation." >&2
  echo "       set CLIPAUDIO_HOST_PYTHON to a python $TARGET_VER binary." >&2
  exit 1
fi
echo "precompiling with $PYBIN (python $TARGET_VER)"
for D in "$STDLIB" "$CODESIGNING_FOLDER_PATH/app_packages"; do
  [ -d "$D" ] || continue
  "$PYBIN" -m compileall -q -b --invalidation-mode unchecked-hash "$D" >/dev/null 2>&1 || true
  # Drop source only where bytecode actually exists, so a file that
  # failed to compile is never silently deleted.
  find "$D" -name '*.py' | while read -r F; do
    [ -f "${F%.py}.pyc" ] && rm -f "$F"
  done
  find "$D" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
done
echo "precompiled bundle: $(du -sh "$CODESIGNING_FOLDER_PATH" | cut -f1)"

