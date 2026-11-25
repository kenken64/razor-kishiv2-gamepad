$ErrorActionPreference = 'Stop'
$windowsPowerShell = if ($env:SystemRoot) {
    Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
} else {
    $null
}
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    if ($PSVersionTable.PSEdition -ne 'Desktop' -and $env:SystemRoot -and (Test-Path -LiteralPath $windowsPowerShell) -and $PSCommandPath) {
        Start-Process -FilePath $windowsPowerShell -ArgumentList "-STA -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        exit
    }
    throw 'This UI needs a single-threaded apartment. Run it with Windows PowerShell.'
}

$wpfReady = $true
try {
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
} catch {
    $wpfReady = $false
}
if (-not $wpfReady) {
    if ($PSVersionTable.PSEdition -ne 'Desktop' -and $windowsPowerShell -and (Test-Path -LiteralPath $windowsPowerShell) -and $PSCommandPath) {
        Start-Process -FilePath $windowsPowerShell -ArgumentList "-STA -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        exit
    }
    throw 'WPF is not available. Run this script with Windows PowerShell.'
}

$darkTitleSource = @'
using System;
using System.Runtime.InteropServices;
public static class KishiDarkTitle {
    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
    public static void Apply(IntPtr hwnd) {
        int value = 1;
        if (DwmSetWindowAttribute(hwnd, 20, ref value, sizeof(int)) != 0) {
            DwmSetWindowAttribute(hwnd, 19, ref value, sizeof(int));
        }
    }
}
'@
if (-not ('KishiDarkTitle' -as [type])) {
    try { Add-Type -TypeDefinition $darkTitleSource -ErrorAction Stop } catch {}
}

$title = 'Kishi Receiver'
try {
    $xamlPath = Join-Path $PSScriptRoot 'ReceiverUi.xaml'
    [xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw
    $window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
} catch {
    [Windows.MessageBox]::Show($_.Exception.Message, $title) | Out-Null
    throw
}

$names = @(
    'StatusBadge','StatusDot','StatusText','RestartButton','StartButton',
    'PairingCode','AddressText','CopyButton','PairingStatusDot','PairingStatus',
    'GamepadButton','MonitorButton','ModeDetail','GamepadStatusIcon','GamepadStatus',
    'GamepadWarning','GamepadWarningText','PeerText',
    'LeftDot','LeftValues','RightDot','RightValues','LTFill','RTFill',
    'LTPercent','RTPercent','LTTrack','RTTrack',
    'DpadUp','DpadLeft','DpadDown','DpadRight','LiveDot','LiveText',
    'ActivityBox','ClearButton','ButtonGrid'
)
$script:ui = @{}
foreach ($name in $names) {
    $script:ui[$name] = $window.FindName($name)
    if ($null -eq $script:ui[$name]) { throw "ReceiverUi.xaml is missing the $name element." }
}

function New-Brush([string]$hex) {
    return [Windows.Media.SolidColorBrush]::new(
        [Windows.Media.ColorConverter]::ConvertFromString($hex)
    )
}

$script:accent = New-Brush '#2DD4BF'
$script:ink = New-Brush '#090D17'
$script:textPrimary = New-Brush '#F3FAF6'
$script:textSecondary = New-Brush '#A8BCBA'
$script:textTertiary = New-Brush '#7F9491'
$script:chipOffBg = New-Brush '#0BFFFFFF'
$script:chipOffStroke = New-Brush '#12FFFFFF'
$script:chipOffText = New-Brush '#A8BCBA'
$script:dpadOffBg = New-Brush '#0BFFFFFF'
$script:dpadOffStroke = New-Brush '#12FFFFFF'

$script:running = $false
$script:receiver = $null
$script:mode = 'gamepad'
$script:pin = $null
$script:address = 'Unavailable'
$script:peer = ''
$script:logPath = $null
$script:errPath = $null
$script:logState = @{ Position = [long]0; Residual = '' }
$script:errState = @{ Position = [long]0; Residual = '' }
$script:chips = @{}
$script:chipDefs = [ordered]@{
    A = 0x1000; B = 0x2000; X = 0x4000; Y = 0x8000
    LB = 0x0100; RB = 0x0200; Back = 0x0020; Start = 0x0010
    Guide = 0x0400; LS = 0x0040; RS = 0x0080
}

function Get-ReceiverExe {
    $release = Join-Path $PSScriptRoot 'target\release\kishi-receiver.exe'
    if (Test-Path -LiteralPath $release) { return $release }
    $debug = Join-Path $PSScriptRoot 'target\debug\kishi-receiver.exe'
    if (Test-Path -LiteralPath $debug) { return $debug }
    return $null
}

function Get-WindowsAddress {
    try {
        $config = Get-NetIPConfiguration |
            Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
            Select-Object -First 1
        if ($config) {
            $address = @($config.IPv4Address)[0]
            if ($address) { return $address.IPAddress }
        }
    } catch {}
    try {
        $address = Get-NetIPAddress -AddressFamily IPv4 |
            Where-Object {
                $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' -and
                $_.PrefixOrigin -ne 'WellKnown'
            } |
            Sort-Object InterfaceMetric |
            Select-Object -First 1
        if ($address) { return $address.IPAddress }
    } catch {}
    try {
        $address = [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
            Where-Object {
                $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and
                -not $_.IPAddressToString.StartsWith('169.254.')
            } |
            Select-Object -First 1
        if ($address) { return $address.IPAddressToString }
    } catch {}
    return 'Unavailable'
}

function Set-Status([string]$text, [string]$color) {
    $brush = New-Brush $color
    $script:ui.StatusText.Text = $text
    $script:ui.StatusText.Foreground = $brush
    $script:ui.StatusDot.Fill = $brush
    $script:ui.StatusBadge.Background = New-Brush ("#1A" + $color.Substring(1))
    $script:ui.StatusBadge.BorderBrush = New-Brush ("#33" + $color.Substring(1))
}

function Set-PairingStatus([string]$text, [string]$color) {
    $script:ui.PairingStatus.Text = $text
    $script:ui.PairingStatus.Foreground = New-Brush $color
    $script:ui.PairingStatusDot.Fill = New-Brush $color
}

function Set-Live([string]$text, [string]$color) {
    $script:ui.LiveText.Text = $text
    $script:ui.LiveDot.Fill = New-Brush $color
}

function Add-Activity([string]$message, [string]$level = 'info') {
    $color = switch ($level) {
        'success' { '#74E0C8' }
        'warning' { '#F5C56B' }
        'error'   { '#FF8A8A' }
        default   { '#9FB3B0' }
    }
    $paragraph = [Windows.Documents.Paragraph]::new()
    $paragraph.Margin = [Windows.Thickness]::new(0, 0, 0, 2)
    $run = [Windows.Documents.Run]::new((Get-Date -Format 'HH:mm:ss.fff') + '  ' + $message)
    $run.Foreground = New-Brush $color
    $run.FontFamily = [Windows.Media.FontFamily]::new('Consolas')
    $run.FontSize = 12
    $paragraph.Inlines.Add($run)
    $script:ui.ActivityBox.Document.Blocks.Add($paragraph)
    while ($script:ui.ActivityBox.Document.Blocks.Count -gt 400) {
        $script:ui.ActivityBox.Document.Blocks.Remove($script:ui.ActivityBox.Document.Blocks.FirstBlock)
    }
    $script:ui.ActivityBox.ScrollToEnd()
}

function Build-Chips {
    foreach ($name in $script:chipDefs.Keys) {
        $chip = [Windows.Controls.Border]::new()
        $chip.Height = 34
        $chip.Margin = [Windows.Thickness]::new(4.5)
        $chip.CornerRadius = [Windows.CornerRadius]::new(7)
        $chip.Background = $script:chipOffBg
        $chip.BorderBrush = $script:chipOffStroke
        $chip.BorderThickness = [Windows.Thickness]::new(1)

        $label = [Windows.Controls.TextBlock]::new()
        $label.Text = $name
        $label.FontSize = 12
        $label.FontWeight = [Windows.FontWeights]::SemiBold
        $label.Foreground = $script:chipOffText
        $label.HorizontalAlignment = 'Center'
        $label.VerticalAlignment = 'Center'
        $chip.Child = $label

        [void]$script:ui.ButtonGrid.Children.Add($chip)
        $script:chips[$name] = $chip
    }
}

function Set-Chip([string]$name, [bool]$on) {
    $chip = $script:chips[$name]
    if ($on) {
        $chip.Background = $script:accent
        $chip.BorderBrush = $script:accent
        $chip.Child.Foreground = $script:ink
    } else {
        $chip.Background = $script:chipOffBg
        $chip.BorderBrush = $script:chipOffStroke
        $chip.Child.Foreground = $script:chipOffText
    }
}

function Set-Dpad([string]$name, [bool]$on) {
    $pad = $script:ui[$name]
    if ($on) {
        $pad.Background = $script:accent
        $pad.BorderBrush = $script:accent
        $pad.Child.Foreground = $script:ink
    } else {
        $pad.Background = $script:dpadOffBg
        $pad.BorderBrush = $script:dpadOffStroke
        $pad.Child.Foreground = $script:textSecondary
    }
}

function Reset-Input {
    foreach ($name in $script:chipDefs.Keys) { Set-Chip $name $false }
    foreach ($name in 'DpadUp','DpadLeft','DpadDown','DpadRight') { Set-Dpad $name $false }
    [Windows.Controls.Canvas]::SetLeft($script:ui.LeftDot, 48)
    [Windows.Controls.Canvas]::SetTop($script:ui.LeftDot, 48)
    [Windows.Controls.Canvas]::SetLeft($script:ui.RightDot, 48)
    [Windows.Controls.Canvas]::SetTop($script:ui.RightDot, 48)
    $script:ui.LeftValues.Text = '0  0'
    $script:ui.RightValues.Text = '0  0'
    $script:ui.LTFill.Width = 0
    $script:ui.RTFill.Width = 0
    $script:ui.LTPercent.Text = '0%'
    $script:ui.RTPercent.Text = '0%'
}

function Set-Input([int]$flags, [int]$lt, [int]$rt, [int]$lx, [int]$ly, [int]$rx, [int]$ry) {
    foreach ($name in $script:chipDefs.Keys) {
        Set-Chip $name (($flags -band [int]$script:chipDefs[$name]) -ne 0)
    }
    Set-Dpad 'DpadUp' (($flags -band 0x0002) -ne 0)
    Set-Dpad 'DpadLeft' (($flags -band 0x0008) -ne 0)
    Set-Dpad 'DpadDown' (($flags -band 0x0001) -ne 0)
    Set-Dpad 'DpadRight' (($flags -band 0x0004) -ne 0)

    $travel = 38.0
    $clampedX = [Math]::Max(-32768, [Math]::Min(32767, $lx))
    $clampedY = [Math]::Max(-32768, [Math]::Min(32767, $ly))
    [Windows.Controls.Canvas]::SetLeft($script:ui.LeftDot, 56 + $clampedX / 32768.0 * $travel - 8)
    [Windows.Controls.Canvas]::SetTop($script:ui.LeftDot, 56 - $clampedY / 32768.0 * $travel - 8)
    $clampedX = [Math]::Max(-32768, [Math]::Min(32767, $rx))
    $clampedY = [Math]::Max(-32768, [Math]::Min(32767, $ry))
    [Windows.Controls.Canvas]::SetLeft($script:ui.RightDot, 56 + $clampedX / 32768.0 * $travel - 8)
    [Windows.Controls.Canvas]::SetTop($script:ui.RightDot, 56 - $clampedY / 32768.0 * $travel - 8)

    $script:ui.LeftValues.Text = "$lx  $ly"
    $script:ui.RightValues.Text = "$rx  $ry"

    $track = $script:ui.LTTrack.ActualWidth
    if ($track -le 0) { $track = 180 }
    $script:ui.LTFill.Width = [Math]::Round($track * [Math]::Max(0, [Math]::Min(255, $lt)) / 255.0, 1)
    $track = $script:ui.RTTrack.ActualWidth
    if ($track -le 0) { $track = 180 }
    $script:ui.RTFill.Width = [Math]::Round($track * [Math]::Max(0, [Math]::Min(255, $rt)) / 255.0, 1)
    $script:ui.LTPercent.Text = [string][int][Math]::Round([Math]::Max(0, [Math]::Min(255, $lt)) / 255.0 * 100) + '%'
    $script:ui.RTPercent.Text = [string][int][Math]::Round([Math]::Max(0, [Math]::Min(255, $rt)) / 255.0 * 100) + '%'
}

function Update-ModeVisuals {
    $selected = $script:accent
    $transparent = [Windows.Media.Brushes]::Transparent
    if ($script:mode -eq 'gamepad') {
        $script:ui.GamepadButton.Background = $selected
        $script:ui.GamepadButton.Foreground = $script:ink
        $script:ui.MonitorButton.Background = $transparent
        $script:ui.MonitorButton.Foreground = $script:textSecondary
        $script:ui.ModeDetail.Text = 'Publishes an Xbox 360 controller through ViGEmBus.'
    } else {
        $script:ui.GamepadButton.Background = $transparent
        $script:ui.GamepadButton.Foreground = $script:textSecondary
        $script:ui.MonitorButton.Background = $selected
        $script:ui.MonitorButton.Foreground = $script:ink
        $script:ui.ModeDetail.Text = 'Pairs and shows input without creating a gamepad.'
    }
    $script:ui.GamepadButton.IsEnabled = -not $script:running
    $script:ui.MonitorButton.IsEnabled = -not $script:running
    Update-GamepadStatus
}

function Update-GamepadStatus {
    if ($script:mode -eq 'monitor') {
        $script:ui.GamepadStatusIcon.Foreground = New-Brush '#F5C56B'
        $script:ui.GamepadStatus.Text = 'Input is visible here but games receive nothing.'
    } elseif ($script:running) {
        $script:ui.GamepadStatusIcon.Foreground = New-Brush '#74E0C8'
        $script:ui.GamepadStatus.Text = 'Xbox 360 controller is published to Windows.'
    } else {
        $script:ui.GamepadStatusIcon.Foreground = New-Brush '#F5C56B'
        $script:ui.GamepadStatus.Text = 'The virtual controller is created when the receiver starts.'
    }
}

function Update-Controls {
    if ($script:running) {
        $script:ui.StartButton.Content = '■  Stop'
        $script:ui.StartButton.Style = $window.Resources['SecondaryButton']
        $script:ui.RestartButton.IsEnabled = $true
    } else {
        $script:ui.StartButton.Content = '▶  Start receiver'
        $script:ui.StartButton.Style = $window.Resources['PrimaryButton']
        $script:ui.RestartButton.IsEnabled = $false
    }
    $script:ui.GamepadButton.IsEnabled = -not $script:running
    $script:ui.MonitorButton.IsEnabled = -not $script:running
}

function Set-Mode([string]$mode) {
    if ($script:running) { return }
    $script:mode = $mode
    $script:ui.GamepadWarning.Visibility = 'Collapsed'
    Update-ModeVisuals
}

function Read-NewLines([string]$path, [hashtable]$state) {
    if ([string]::IsNullOrEmpty($path) -or -not (Test-Path -LiteralPath $path)) { return @() }
    $stream = $null
    $reader = $null
    try {
        $stream = [System.IO.File]::Open(
            $path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )
        [void]$stream.Seek([long]$state.Position, [System.IO.SeekOrigin]::Begin)
        $reader = [System.IO.StreamReader]::new($stream)
        $text = $reader.ReadToEnd()
        $state.Position = $stream.Position
    } catch {
        return @()
    } finally {
        if ($reader) { $reader.Dispose() } elseif ($stream) { $stream.Dispose() }
    }

    $text = [string]$state.Residual + $text
    $parts = $text -split "`r?`n"
    if ($text.EndsWith("`n")) {
        $state.Residual = ''
        if ($parts.Length -gt 0) { $parts = $parts[0..($parts.Length - 2)] }
    } else {
        $state.Residual = $parts[-1]
        if ($parts.Length -le 1) { $parts = @() } else { $parts = $parts[0..($parts.Length - 2)] }
    }
    return @($parts | Where-Object { $_ -ne '' })
}

function Show-GamepadWarning([string]$message) {
    $script:ui.GamepadWarning.Visibility = 'Visible'
    $script:ui.GamepadWarningText.Text = $message
}

function Handle-ReceiverLine([string]$line) {
    if ($line.StartsWith('[STATE] ')) {
        $values = $line.Substring(8).Trim() -split '\s+'
        if ($values.Count -eq 7) {
            Set-Input ([int]$values[0]) ([int]$values[1]) ([int]$values[2]) `
                ([int]$values[3]) ([int]$values[4]) ([int]$values[5]) ([int]$values[6])
        }
        return
    }

    $message = $line
    if ($line -match '^\d{4}-\d{2}-\d{2}T\S+\s+(.*)$') { $message = $Matches[1] }
    $level = 'info'
    if ($message -match '^\[CONNECTED\]|Pairing code|^\[RESUMED\]') { $level = 'success' }
    elseif ($message -match '^\[PAIRING FAILED\]|^\[STALLED\]|^\[DISCONNECTED\]|Cannot ') { $level = 'warning' }
    if ($message -match 'Cannot open ViGEmBus') {
        $level = 'error'
        Show-GamepadWarning ($message -replace '^Cannot open ViGEmBus', 'Install ViGEmBus, then restart the receiver.')
    }

    if ($message -match 'Pairing code (\d{6})') {
        $script:pin = $Matches[1]
        $script:ui.PairingCode.Text = $script:pin
    }
    if ($message -match '^\[LISTENING\]') {
        Reset-Input
        Set-Status 'Waiting for phone' '#38BDF8'
        Set-PairingStatus 'Listening on TCP 26760' '#38BDF8'
        Set-Live 'No phone' '#66706F'
    } elseif ($message -match '^\[CONNECTED\]\s*(.*)$') {
        Reset-Input
        $script:peer = $Matches[1]
        Set-Status 'Connected' '#74E0C8'
        Set-PairingStatus ("Streaming input from " + $script:peer) '#74E0C8'
        $script:ui.PeerText.Text = "Connected to " + $script:peer
        Set-Live 'Streaming' '#74E0C8'
    } elseif ($message -match '^\[DISCONNECTED\]') {
        Reset-Input
        Set-Status 'Waiting for phone' '#38BDF8'
        Set-PairingStatus 'Waiting for a phone to pair' '#38BDF8'
        $script:ui.PeerText.Text = if ($script:peer) { "Last peer " + $script:peer } else { 'No phone connected' }
        Set-Live 'No phone' '#66706F'
    } elseif ($message -match '^\[PAIRING FAILED\]') {
        Reset-Input
        Set-Status 'Pairing failed' '#FF8A8A'
        Set-PairingStatus ($message -replace '^\[PAIRING FAILED\]\s*', '') '#FF8A8A'
        Set-Live 'No phone' '#66706F'
    } elseif ($message -match '^\[STALLED\]') {
        Reset-Input
        Set-Status 'Controls released' '#F5C56B'
        Set-Live 'Idle' '#F5C56B'
    } elseif ($message -match '^\[RESUMED\]') {
        Set-Status 'Connected' '#74E0C8'
        Set-Live 'Streaming' '#74E0C8'
    }
    Add-Activity $message $level
}

function Read-ReceiverLog {
    if (-not $script:running) { return }

    foreach ($line in (Read-NewLines $script:logPath $script:logState)) {
        Handle-ReceiverLine $line
    }
    foreach ($line in (Read-NewLines $script:errPath $script:errState)) {
        Handle-ReceiverLine $line
    }

    if ($script:receiver -and $script:receiver.HasExited) {
        $code = $script:receiver.ExitCode
        Reset-Input
        $script:ui.PairingCode.Text = '------'
        Set-Status 'Error' '#FF8A8A'
        Set-PairingStatus ("Receiver exited with code " + $code) '#FF8A8A'
        Set-Live 'No phone' '#66706F'
        Add-Activity ("Receiver exited with code " + $code + ". Check the activity log above.") 'error'
        $script:receiver = $null
        $script:running = $false
        Update-Controls
        Update-GamepadStatus
    }
}

function Start-Receiver {
    if ($script:running) { return }
    $exe = Get-ReceiverExe
    if (-not $exe) {
        Set-Status 'Error' '#FF8A8A'
        Add-Activity 'Receiver executable not found. Build it with cargo build --locked --release --manifest-path server/Cargo.toml.' 'error'
        return
    }

    $script:address = Get-WindowsAddress
    $script:ui.AddressText.Text = $script:address
    $existing = Get-NetTCPConnection -State Listen -LocalPort 26760 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($existing) {
        try {
            $process = Get-Process -Id $existing.OwningProcess -ErrorAction Stop
            if ($process.ProcessName -eq 'kishi-receiver' -or $process.Path -eq $exe) {
                Stop-Process -Id $process.Id -Force
                Wait-Process -Id $process.Id -Timeout 2 -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 300
                Add-Activity 'Replaced an existing receiver process.' 'warning'
            } else {
                throw ("TCP port 26760 is used by " + $process.ProcessName + ".")
            }
        } catch {
            Set-Status 'Error' '#FF8A8A'
            Add-Activity $_.Exception.Message 'error'
            return
        }
    }

    $script:logPath = Join-Path $env:TEMP ('kishi-ui-' + [Guid]::NewGuid().ToString('N') + '.log')
    $script:errPath = $script:logPath + '.err'
    $script:logState = @{ Position = [long]0; Residual = '' }
    $script:errState = @{ Position = [long]0; Residual = '' }
    $script:pin = $null
    $script:peer = ''
    $script:ui.PairingCode.Text = '------'
    $script:ui.PeerText.Text = 'No phone connected'
    $script:ui.GamepadWarning.Visibility = 'Collapsed'
    Reset-Input

    $arguments = @('--ui')
    if ($script:mode -eq 'monitor') { $arguments += '--monitor' }
    try {
        $script:receiver = Start-Process -FilePath $exe -ArgumentList $arguments -WindowStyle Hidden `
            -RedirectStandardOutput $script:logPath -RedirectStandardError $script:errPath -PassThru
    } catch {
        Set-Status 'Error' '#FF8A8A'
        Add-Activity $_.Exception.Message 'error'
        return
    }

    $script:running = $true
    Update-Controls
    Update-ModeVisuals
    Set-Status 'Starting...' '#38BDF8'
    Set-PairingStatus 'Starting receiver on TCP 26760' '#38BDF8'
    Add-Activity ('Starting receiver in ' + $script:mode + ' mode.') 'info'
    Read-ReceiverLog
}

function Stop-Receiver([bool]$quiet = $false) {
    if ($script:receiver -and -not $script:receiver.HasExited) {
        $processId = $script:receiver.Id
        try {
            Stop-Process -Id $processId -Force
            Wait-Process -Id $processId -Timeout 2 -ErrorAction SilentlyContinue
        } catch {}
    }
    $script:receiver = $null
    $script:running = $false
    Reset-Input
    $script:ui.PairingCode.Text = '------'
    $script:ui.PeerText.Text = 'No phone connected'
    $script:ui.GamepadWarning.Visibility = 'Collapsed'
    Set-Status 'Stopped' '#8A9A97'
    Set-PairingStatus 'Receiver is not listening' '#7F9491'
    Set-Live 'No phone' '#66706F'
    if (-not $quiet) { Add-Activity 'Receiver stopped.' 'info' }
    Update-Controls
    Update-ModeVisuals
}

function Restart-Receiver {
    if (-not $script:running) {
        Start-Receiver
        return
    }
    Add-Activity 'Restarting receiver with a new pairing code.' 'info'
    Stop-Receiver $true
    $restart = [Windows.Threading.DispatcherTimer]::new()
    $restart.Interval = [TimeSpan]::FromMilliseconds(350)
    $restart.Add_Tick({
        $restart.Stop()
        Start-Receiver
    })
    $restart.Start()
}

$workArea = [Windows.SystemParameters]::WorkArea
$window.MaxWidth = $workArea.Width
$window.MaxHeight = $workArea.Height
if ($window.Height -gt $workArea.Height - 16) {
    $window.Height = [Math]::Max(680, $workArea.Height - 16)
}
if ($window.Width -gt $workArea.Width - 16) {
    $window.Width = [Math]::Max(1000, $workArea.Width - 16)
}

Build-Chips
$script:address = Get-WindowsAddress
$script:ui.AddressText.Text = $script:address
$script:ui.RestartButton.IsEnabled = $false
Update-ModeVisuals
Update-Controls
Reset-Input
Set-Status 'Stopped' '#8A9A97'
Set-PairingStatus 'Receiver is not listening' '#7F9491'

$script:ui.StartButton.Add_Click({
    if ($script:running) { Stop-Receiver } else { Start-Receiver }
})
$script:ui.RestartButton.Add_Click({ Restart-Receiver })
$script:ui.GamepadButton.Add_Click({ Set-Mode 'gamepad' })
$script:ui.MonitorButton.Add_Click({ Set-Mode 'monitor' })
$script:ui.CopyButton.Add_Click({
    if ($script:address -ne 'Unavailable') {
        try {
            [Windows.Clipboard]::SetText($script:address)
            Add-Activity ('Copied ' + $script:address + ' to the clipboard.') 'info'
        } catch {
            Add-Activity 'Could not access the clipboard.' 'warning'
        }
    }
})
$script:ui.ClearButton.Add_Click({
    $script:ui.ActivityBox.Document.Blocks.Clear()
})

$timer = [Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromMilliseconds(100)
$timer.Add_Tick({ Read-ReceiverLog })
$timer.Start()

$window.Add_SourceInitialized({
    try {
        $helper = [Windows.Interop.WindowInteropHelper]::new($window)
        [KishiDarkTitle]::Apply($helper.Handle)
    } catch {}
})

$window.Add_Closed({
    $timer.Stop()
    Stop-Receiver $true
})

$window.Add_Loaded({
    Start-Receiver
})

try {
    [void]$window.ShowDialog()
} finally {
    if ($script:running -or $script:receiver) { Stop-Receiver $true }
}
