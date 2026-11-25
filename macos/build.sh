#!/bin/sh
# Build the native macOS receiver UI.
#
# Usage:
#   ./macos/build.sh
#   ARCHS="arm64 x86_64" ./macos/build.sh
#   SIGNING_IDENTITY="Apple Development: ... (TEAMID)" \
#   PROVISIONING_PROFILE="/path/profile.provisionprofile" ./macos/build.sh
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
build="$here/build"
app="$build/Kishi Receiver.app"
sdk=$(xcrun --show-sdk-path)
archs=${ARCHS:-$(uname -m)}
if [ "$archs" = "universal" ]; then
    archs="arm64 x86_64"
fi

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

set -- "$here"/KishiReceiver/*.swift
for arch in $archs; do
    out="$build/kishi-receiver-$arch"
    echo "Compiling $arch..."
    swiftc \
        -swift-version 5 \
        -parse-as-library \
        -O \
        -target "$arch-apple-macosx13.0" \
        -sdk "$sdk" \
        -framework SwiftUI \
        -framework AppKit \
        -framework Network \
        -framework IOKit \
        -o "$out" \
        "$@"
done

case "$archs" in
    *" "*)
        lipo -create "$build"/kishi-receiver-* -output "$app/Contents/MacOS/kishi-receiver"
        ;;
    *)
        cp "$build/kishi-receiver-$archs" "$app/Contents/MacOS/kishi-receiver"
        ;;
esac

cp "$here/Info.plist" "$app/Contents/Info.plist"
printf 'APPL????' > "$app/Contents/PkgInfo"
plutil -lint "$app/Contents/Info.plist" > /dev/null
chmod 755 "$app/Contents/MacOS/kishi-receiver"

if [ -n "${SIGNING_IDENTITY:-}" ]; then
    : "${PROVISIONING_PROFILE:?Set PROVISIONING_PROFILE with SIGNING_IDENTITY.}"
    sh "$here/sign-macos.sh" "$app" "$PROVISIONING_PROFILE" "$SIGNING_IDENTITY"
else
    codesign --force --sign - "$app" > /dev/null 2>&1
    codesign --verify --strict "$app"
    echo "Built unsigned (ad-hoc) app: $app"
    echo "It runs in Monitor mode. Set SIGNING_IDENTITY and PROVISIONING_PROFILE for gamepad output."
fi

echo "Open it with: open \"$app\""
