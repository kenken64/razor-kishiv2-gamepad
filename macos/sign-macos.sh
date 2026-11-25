#!/bin/sh
# Sign the built Kishi Receiver.app for virtual gamepad output.
#
# The provisioning profile must use an explicit macOS App ID with the
# com.apple.developer.hid.virtual.device entitlement enabled.
set -eu
if [ "$#" -ne 3 ]; then
    echo 'Usage: sh sign-macos.sh "Kishi Receiver.app" PROVISIONING_PROFILE SIGNING_IDENTITY' >&2
    exit 2
fi

app=$1
profile=$2
identity=$3
if [ ! -d "$app" ]; then
    echo "App bundle not found: $app" >&2
    exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
security cms -D -i "$profile" > "$work/profile.plist"
profile_value() {
    /usr/libexec/PlistBuddy -c "Print :Entitlements:$1" "$work/profile.plist"
}
if [ "$(profile_value com.apple.developer.hid.virtual.device)" != true ]; then
    echo 'The profile must authorize com.apple.developer.hid.virtual.device.' >&2
    exit 1
fi

app_id=$(profile_value com.apple.application-identifier)
team=$(profile_value com.apple.developer.team-identifier)
bundle_id=${app_id#*.}
case "$bundle_id" in
    ''|*[!A-Za-z0-9.-]*) echo 'Use a profile with an explicit bundle identifier.' >&2; exit 1 ;;
esac

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$app/Contents/Info.plist"
cp "$profile" "$app/Contents/embedded.provisionprofile"

ents="$work/Entitlements.plist"
plutil -create xml1 "$ents"
/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $app_id" "$ents"
/usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $team" "$ents"
/usr/libexec/PlistBuddy -c "Add :com.apple.developer.hid.virtual.device bool true" "$ents"

codesign --force --options runtime --sign "$identity" --entitlements "$ents" "$app"
codesign --verify --strict --verbose=2 "$app"
echo "Signed with virtual HID entitlement: $app"
