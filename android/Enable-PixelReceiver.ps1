param(
    [string]$Serial,
    [string]$Adb = 'D:\Android\Sdk\platform-tools\adb.exe'
)
$ErrorActionPreference = 'Stop'
if (!(Test-Path -LiteralPath $Adb)) { $Adb = (Get-Command adb.exe).Source }
$device = if ($Serial) { @('-s', $Serial) } else { @('-d') }
function Invoke-Pixel([string[]]$Arguments) {
    $result = & $Adb @device @Arguments
    if ($LASTEXITCODE) { throw "ADB failed ($LASTEXITCODE). Connect and authorize the Pixel, then retry." }
    $result
}
$product = (Invoke-Pixel @('shell','getprop','ro.product.device')).Trim()
if ($product -ne 'cheetah') { throw "Expected a Pixel 7 Pro (cheetah), found $product." }
$apk = Join-Path $PSScriptRoot 'build\Kishi-WiFi.apk'
if (!(Test-Path -LiteralPath $apk)) { throw "Build the APK with android\build.ps1 first." }
Invoke-Pixel @('install','-r',$apk)
$setup = @'
set -eu
test -w /dev/uhid || { echo "ADB shell cannot access the virtual gamepad device (/dev/uhid)"; exit 1; }
export CLASSPATH=$(pm path net.kishi.bridge | sed -n '1s/^package://p')
test -r "$CLASSPATH"
key=$(content call --uri content://net.kishi.bridge.helper --method setup | sed -n 's/.*key=\([A-Za-z0-9_-]*\).*/\1/p')
[ "${#key}" -eq 43 ] || { echo "Could not provision gamepad helper"; exit 1; }
proc=net.kishi.bridge.helper
old=$(pidof "$proc" || true)
if [ -n "$old" ]; then
    for p in $old; do
        [ "$(tr '\000' '\n' < /proc/$p/cmdline | head -1)" = "$proc" ] || exit 1
        kill "$p"
    done
    sleep 1
fi
log=/data/local/tmp/kishi-gamepad-helper.log
umask 077
printf '%s\n' "$key" | nohup app_process /system/bin --nice-name="$proc" net.kishi.bridge.GamepadHelper >"$log" 2>&1 &
for attempt in 1 2 3 4 5; do
    sleep 1
    if grep -q 'Gamepad helper ready' "$log" && pidof "$proc" >/dev/null; then
        am start -n net.kishi.bridge/.Bridge
        echo "Open Receiver mode on the Pixel and tap Start receiver. USB can now be unplugged."
        exit 0
    fi
done
cat "$log"
exit 1
'@
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($setup.Replace("`r", '') + "`n"))
& $Adb @device shell "echo $encoded | base64 -d | sh"
if ($LASTEXITCODE) { throw "Pixel helper setup failed ($LASTEXITCODE)." }
