#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
DEVELOPER_DIR_PATH="$(xcode-select -p)"
if [[ "$DEVELOPER_DIR_PATH" == */CommandLineTools ]]; then
    FRAMEWORKS="$DEVELOPER_DIR_PATH/Library/Developer/Frameworks"
    swift test --disable-sandbox --disable-xctest \
        -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
        -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
        -Xlinker -F -Xlinker "$FRAMEWORKS" \
        -Xlinker -rpath -Xlinker "$FRAMEWORKS"
else
    swift test --disable-xctest
fi
