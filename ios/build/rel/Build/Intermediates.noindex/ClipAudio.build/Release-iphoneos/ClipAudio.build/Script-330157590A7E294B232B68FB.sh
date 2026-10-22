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

