#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$here/build"
swiftc \
    -swift-version 5 \
    -O \
    -o "$here/build/protocol-tests" \
    "$here/KishiReceiver/GamepadState.swift" \
    "$here/tests/main.swift"
"$here/build/protocol-tests"
