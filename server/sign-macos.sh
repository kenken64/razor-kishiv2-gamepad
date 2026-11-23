#!/bin/sh
# Package a local receiver using a profile for an explicit macOS App ID.
set -eu
if [ "$#" -ne 3 ]; then
    echo 'Usage: sh sign-macos.sh RECEIVER PROVISIONING_PROFILE SIGNING_IDENTITY' >&2
    exit 2
fi
binary=$1
profile=$2
identity=$3
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
app="$work/Kishi Receiver.app"
mkdir -p "$app/Contents/MacOS"
install -m 755 "$binary" "$app/Contents/MacOS/kishi-receiver"
cp "$profile" "$app/Contents/embedded.provisionprofile"
info="$app/Contents/Info.plist"
plutil -create xml1 "$info"
plutil -insert CFBundleIdentifier -string "$bundle_id" "$info"
plutil -insert CFBundleExecutable -string kishi-receiver "$info"
plutil -insert CFBundlePackageType -string APPL "$info"
plutil -insert CFBundleVersion -string 1 "$info"
ents="$work/Entitlements.plist"
plutil -create xml1 "$ents"
/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $app_id" "$ents"
/usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $team" "$ents"
/usr/libexec/PlistBuddy -c "Add :com.apple.developer.hid.virtual.device bool true" "$ents"
codesign --force --options runtime --sign "$identity" --entitlements "$ents" "$app"
codesign --verify --strict "$app"
if [ -e './Kishi Receiver.app' ]; then
    echo 'Move the existing Kishi Receiver.app before creating another copy.' >&2
    exit 1
fi
ditto "$app" './Kishi Receiver.app'
echo 'Run "./Kishi Receiver.app/Contents/MacOS/kishi-receiver" in Terminal to see the pairing code.'
