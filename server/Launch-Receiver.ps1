param([switch]$StartMinimized)
$ErrorActionPreference = 'Stop'
$forwardedSwitch = if ($StartMinimized) { '-StartMinimized' } else { '' }
$windowsPowerShell = if ($env:SystemRoot) {
    Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
} else {
    $null
}
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    if ($PSVersionTable.PSEdition -ne 'Desktop' -and $env:SystemRoot -and (Test-Path -LiteralPath $windowsPowerShell) -and $PSCommandPath) {
        Start-Process -FilePath $windowsPowerShell -WindowStyle Hidden -ArgumentList "-STA -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $forwardedSwitch"
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
        Start-Process -FilePath $windowsPowerShell -WindowStyle Hidden -ArgumentList "-STA -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $forwardedSwitch"
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
    [xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
    $window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
} catch {
    [Windows.MessageBox]::Show($_.Exception.Message, $title) | Out-Null
    throw
}

$names = @(
    'StatusBadge','StatusDot','StatusText','RestartButton','StartButton',
    'PairingCode','QrButton','QrPopup','PairQrImage','AddressText','CopyButton','PairingStatusDot','PairingStatus',
    'GamepadButton','MonitorButton','ModeDetail','GamepadStatusIcon','GamepadStatus',
    'GamepadWarning','GamepadWarningText','PeerText',
    'LeftStick','RightStick','LeftDot','LeftValues','RightDot','RightValues','LTFill','RTFill',
    'LTPercent','RTPercent','LTTrack','RTTrack',
    'DpadUp','DpadLeft','DpadDown','DpadRight','LiveDot','LiveText',
    'ActivityBox','ClearButton','ButtonGrid',
    'ModelVisibility','ModelEyeSlash','CharacterCard','Dashboard','PreviewHost','WukongPreview','FullscreenOverlay','FullscreenHost','EnterFullscreen','ExitFullscreen',
    'CharacterName','ChooseModel','FullscreenChooseModel','Wukong','WukongCamera','WukongFloor','WukongImpact','SpinTrail','SpinButton','SlamButton','JumpButton','FightButton','DodgeButton','RunToggle','ResetCamera','WukongYaw','WukongFlip','WukongMove','WukongHint'
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
    # Cargo can place builds outside the checkout through its environment or config.
    if (Get-Command cargo -ErrorAction SilentlyContinue) {
        $manifest = Join-Path $PSScriptRoot 'Cargo.toml'
        $metadata = cargo metadata --no-deps --format-version 1 --manifest-path $manifest 2>$null
        if ($LASTEXITCODE -eq 0 -and $metadata) {
            $target = ($metadata | ConvertFrom-Json).target_directory
            foreach ($profile in 'release','debug') {
                $candidate = Join-Path $target "$profile\kishi-receiver.exe"
                if (Test-Path -LiteralPath $candidate) { return $candidate }
            }
        }
    }
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

function Set-WukongFullscreen([bool]$enabled) {
    if ($enabled -eq ($script:ui.FullscreenOverlay.Visibility -eq 'Visible')) { return }
    if ($enabled) {
        $script:dashboardWindow = @{
            State = $window.WindowState; Style = $window.WindowStyle; Resize = $window.ResizeMode
            MaxWidth = $window.MaxWidth; MaxHeight = $window.MaxHeight
        }
        $script:ui.PreviewHost.Child = $null
        $script:ui.FullscreenHost.Child = $script:ui.WukongPreview
        $script:ui.Dashboard.Visibility = 'Collapsed'
        $script:ui.FullscreenOverlay.Visibility = 'Visible'
        $window.WindowState = 'Normal'
        $window.MaxWidth = [double]::PositiveInfinity
        $window.MaxHeight = [double]::PositiveInfinity
        $window.WindowStyle = 'None'
        $window.ResizeMode = 'NoResize'
        $window.WindowState = 'Maximized'
        [void]$script:ui.ExitFullscreen.Focus()
    } else {
        $window.WindowState = 'Normal'
        $window.ResizeMode = $script:dashboardWindow.Resize
        $window.WindowStyle = $script:dashboardWindow.Style
        $window.MaxWidth = $script:dashboardWindow.MaxWidth
        $window.MaxHeight = $script:dashboardWindow.MaxHeight
        $window.WindowState = $script:dashboardWindow.State
        $script:ui.FullscreenHost.Child = $null
        $script:ui.PreviewHost.Child = $script:ui.WukongPreview
        $script:ui.FullscreenOverlay.Visibility = 'Collapsed'
        $script:ui.Dashboard.Visibility = 'Visible'
        $script:ui.WukongCamera.FieldOfView = 49
        [void]$script:ui.EnterFullscreen.Focus()
    }
}

function Get-AnimationRole([string]$name) {
    $key = (($name -split ':')[-1] -replace '^(?i:mixamorig[0-9]*|bip[0-9]+)[_ .-]*','').ToLowerInvariant()
    $side = ''
    if ($key -match '^(left|right)[_ .-]*(.+)$') {
        $side = $Matches[1].Substring(0,1).ToUpperInvariant()
        $key = $Matches[2]
    } elseif ($key -match '^(.+?)[_ .-](left|right|l|r)$') {
        $side = $Matches[2].Substring(0,1).ToUpperInvariant()
        $key = $Matches[1]
    } elseif ($key -match '^([lr])[_ .-](.+)$') {
        $side = $Matches[1].ToUpperInvariant()
        $key = $Matches[2]
    }
    $key = $key -replace '[_ .-]',''
    $roles = @{
        hips='Hips'; pelvis='Hips'; spine='Spine'; chest='Chest'; spine1='Chest'; upperchest='Chest'
        clavicle='Clavicle'; shoulder='Clavicle'; arm='UpperArm'; upperarm='UpperArm'
        forearm='Forearm'; lowerarm='Forearm'; hand='Hand'; wrist='Hand'
        thigh='Thigh'; upleg='Thigh'; upperleg='Thigh'; shin='Shin'; calf='Shin'; leg='Shin'; lowerleg='Shin'
        foot='Foot'; ankle='Foot'; toe='Toe'; toebase='Toe'; neck='Neck'; head='Head'
    }
    if (!$roles.ContainsKey($key)) { return $name }
    if ($side) { return $roles[$key] + '.' + $side }
    return $roles[$key]
}

function Read-CharacterRig([string]$path) {
    $bytes = [IO.File]::ReadAllBytes($path)
    if ($bytes.Length -lt 28 -or [BitConverter]::ToUInt32($bytes,0) -ne 0x46546C67 -or
        [BitConverter]::ToUInt32($bytes,4) -ne 2) { throw 'Choose a binary glTF 2.0 file.' }
    $jsonLength = [BitConverter]::ToInt32($bytes, 12)
    $model = [Text.Encoding]::UTF8.GetString($bytes, 20, $jsonLength) | ConvertFrom-Json
    $binaryStart = 28 + $jsonLength
    if ($model.skins.Count -ne 1 -or $model.buffers.Count -ne 1) {
        throw 'Choose a character with one embedded buffer and one compatible humanoid skin.'
    }
    $jointNames = foreach ($index in $model.skins[0].joints) { Get-AnimationRole $model.nodes[$index].name }
    foreach ($required in 'Hips','Chest','UpperArm.R','Hand.R','Thigh.L','Thigh.R','Shin.L','Shin.R') {
        if ($required -cnotin $jointNames) { throw "Missing character joint: $required." }
    }
    foreach ($node in $model.nodes) {
        if ($node.matrix -or $node.rotation -or $node.scale -or
            ($null -ne $node.mesh -and ($node.translation -or $node.skin -ne 0))) {
            throw 'This player supports translation-only bind joints and meshes stored in bind space.'
        }
    }
    $rig = [WukongRig]::new()
    $skin = $model.skins[0]
    $parents = @{}
    foreach ($nodeIndex in $skin.joints) {
        foreach ($child in $model.nodes[$nodeIndex].children) { $parents[$child] = $nodeIndex }
    }
    $nodeToBone = @{}
    $jointMap = [int[]]::new($skin.joints.Count)
    while ($nodeToBone.Count -lt $skin.joints.Count) {
        $previous = $nodeToBone.Count
        for ($i=0; $i -lt $skin.joints.Count; $i++) {
            $nodeIndex = $skin.joints[$i]
            if ($nodeToBone.ContainsKey($nodeIndex)) { continue }
            $parent = -1
            if ($parents.ContainsKey($nodeIndex)) {
                $p = $parents[$nodeIndex]
                if (!$nodeToBone.ContainsKey($p)) { continue }
                $parent = $nodeToBone[$p]
            }
            $t = $model.nodes[$nodeIndex].translation
            if (!$t) { $t = @(0,0,0) }
            $jointMap[$i] = $nodeToBone.Count
            $nodeToBone[$nodeIndex] = $jointMap[$i]
            $rig.AddBone($jointNames[$i], $parent, $t[0], $t[1], $t[2])
        }
        if ($nodeToBone.Count -eq $previous) { throw 'The skeleton contains an invalid joint hierarchy.' }
    }
    foreach ($mesh in $model.meshes) {
        foreach ($part in $mesh.primitives) {
            $position = $model.accessors[$part.attributes.POSITION]
            if ($null -eq $part.attributes.NORMAL -or $null -eq $part.attributes.JOINTS_0 -or
                $null -eq $part.attributes.WEIGHTS_0 -or $null -eq $part.indices -or
                ($null -ne $part.mode -and $part.mode -ne 4)) {
                throw 'Meshes need indexed triangles, normals and four joint weights per vertex.'
            }
            $normal = $model.accessors[$part.attributes.NORMAL]
            $index = $model.accessors[$part.indices]
            $joints = $model.accessors[$part.attributes.JOINTS_0]
            $weights = $model.accessors[$part.attributes.WEIGHTS_0]
            $accessors = @($position,$normal,$index,$joints,$weights)
            $formats = @(5126,5126,5123,5121,5126)
            $types = @('VEC3','VEC3','SCALAR','VEC4','VEC4')
            $sizes = @(12,12,2,4,16)
            $offsets = for ($i=0; $i -lt $accessors.Count; $i++) {
                $acc = $accessors[$i]
                $view = $model.bufferViews[$acc.bufferView]
                $length = [long]$acc.count * $sizes[$i]
                $start = $binaryStart + $view.byteOffset + $acc.byteOffset
                if ($acc.componentType -ne $formats[$i] -or $acc.type -ne $types[$i] -or
                    ($view.byteStride -and $view.byteStride -ne $sizes[$i]) -or $acc.sparse -or
                    $acc.count -le 0 -or ($i -ne 2 -and $acc.count -ne $position.count) -or
                    $length + $acc.byteOffset -gt $view.byteLength -or $start + $length -gt $bytes.Length) {
                    throw 'Unsupported or invalid vertex layout. Use the packed layout of the bundled characters.'
                }
                $start
            }
            $color = @(1,1,1,1)
            if ($null -ne $part.material) {
                $factor = $model.materials[$part.material].pbrMetallicRoughness.baseColorFactor
                if ($factor) { $color = $factor }
            }
            $rig.AddMesh($bytes, $offsets[0], $offsets[1],
                $position.count, $offsets[2], $index.count, $offsets[3], $offsets[4], $jointMap, $color[0], $color[1], $color[2])
        }
    }
    $character = [IO.Path]::GetFileNameWithoutExtension($path) -replace '(?i)[ _-]+rigged$','' -replace '[ _-]+',' '
    $rig.BindEquipment(($character -in 'Tang Seng','Tang Jeng'))
    if ($character -in 'Bull Demon King','Sha Seng','Tang Seng','Tang Jeng') { $rig.UseTwoHandedPush() }
    return $rig
}

$script:assetDirectory = Join-Path $PSScriptRoot 'assets'

function Get-CharacterFiles {
    if (Test-Path -LiteralPath $script:assetDirectory -PathType Container) {
        Get-ChildItem -LiteralPath $script:assetDirectory -Filter '*.glb' -File | Sort-Object Name
    }
}

$script:chineseNames = @{
    'Bull Demon King' = '牛魔王'
    'Princess Iron Fan' = '铁扇公主'
    'Sha Seng' = '沙僧'
    'Sun Wukong' = '孙悟空'
    'Tang Seng' = '唐僧'
    'Zhu Bajie' = '猪八戒'
}

function Get-CharacterName([string]$path) {
    $stem = [IO.Path]::GetFileNameWithoutExtension($path)
    $name = (($stem -replace '(?i)[ _-]+rigged$','') -replace '[ _)-]+',' ').Trim()
    if ($name -eq 'Tang Jeng') { $name = 'Tang Seng' }
    if ($script:chineseNames.ContainsKey($name)) { return "$name ($($script:chineseNames[$name]))" }
    if ($name) { return $name }
    return $stem
}

function Select-Character([string]$path) {
    $rig = Read-CharacterRig $path
    if ($script:scene) {
        $script:scene.SelectRig($rig)
    } else {
        $script:scene = [WukongScene]::new($rig, $script:ui.WukongCamera, $script:ui.WukongMove, $script:ui.WukongYaw, $script:ui.WukongFlip)
        $script:ui.WukongImpact.Content = $script:scene.Impact
        $script:ui.SpinTrail.Content = $script:scene.SpinTrail
        $script:scene.Step(0)
    }
    $script:ui.Wukong.Content = $rig.Model
    $script:characterPath = $path
    $script:ui.CharacterName.Text = Get-CharacterName $path
    $script:ui.FullscreenChooseModel.Content = $script:ui.CharacterName.Text + ' ▾'
    $script:ui.WukongHint.Text = 'Left stick to walk · Right stick to orbit'
    return $rig
}

function Show-CharacterPicker($button) {
    $menu = [Windows.Controls.ContextMenu]::new()
    $menu.PlacementTarget = $button
    $menu.Placement = 'Bottom'
    $files = @(Get-CharacterFiles)
    $names = @{}
    foreach ($file in $files) { $names[(Get-CharacterName $file.Name)]++ }
    foreach ($file in $files) {
        $item = [Windows.Controls.MenuItem]::new()
        $name = Get-CharacterName $file.Name
        $item.Header = if ($names[$name] -gt 1) { "$name — $($file.BaseName.Replace('_','__'))" } else { $name }
        $item.Tag = $file.FullName
        $item.IsChecked = $file.FullName -eq $script:characterPath
        $item.Add_Click({
            param($sender,$eventArgs)
            try { [void](Select-Character $sender.Tag) }
            catch { [void][Windows.MessageBox]::Show($window,$_.Exception.Message,'Could not load character','OK','Warning') }
        })
        [void]$menu.Items.Add($item)
    }
    if (!$files.Count) {
        $item = [Windows.Controls.MenuItem]::new()
        $item.Header = 'Add a GLB to server/assets'
        $item.IsEnabled = $false
        [void]$menu.Items.Add($item)
    }
    $menu.IsOpen = $true
}

function Initialize-Wukong {
    try {
        $references = @([Windows.Media.Media3D.Model3D].Assembly.Location,
                        [Windows.DependencyObject].Assembly.Location)
        Add-Type -Path (Join-Path $PSScriptRoot 'WukongMesh.cs') -ReferencedAssemblies $references
        $script:ui.WukongFloor.Content = [WukongScene]::Floor()
        $files = Get-CharacterFiles | Sort-Object { $_.Name -ne 'Sun_Wukong_Rigged.glb' }, Name
        foreach ($file in $files) {
            try { [void](Select-Character $file.FullName); return }
            catch { Add-Activity ($file.Name + ': ' + $_.Exception.Message) 'warning' }
        }
        $script:ui.CharacterName.Text = 'Character'
        $script:ui.WukongHint.Text = 'Add a compatible GLB to server/assets, then choose a model.'
    } catch {
        $script:ui.WukongHint.Text = 'Model preview unavailable.'
        Add-Activity $_.Exception.Message 'warning'
    }
}

$script:phoneStick = @{ Left = @(0,0); Right = @(0,0) }

function Show-Stick([string]$side, [int]$x, [int]$y) {
    $dot = $script:ui[$side + 'Dot']
    [Windows.Controls.Canvas]::SetLeft($dot, 48 + 38 * ($x / 32768.0))
    [Windows.Controls.Canvas]::SetTop($dot, 48 - 38 * ($y / 32768.0))
    $script:ui[$side + 'Values'].Text = "$x  $y"
    if (!$script:scene) { return }
    if ($side -eq 'Left') {
        $script:scene.MoveX = $x / 32768.0
        $script:scene.MoveY = $y / 32768.0
    } else {
        $script:scene.LookX = $x / 32768.0
        $script:scene.LookY = $y / 32768.0
    }
}

function Set-PhoneStick([string]$side, [int]$x, [int]$y) {
    $script:phoneStick[$side] = @($x,$y)
    if (!$script:ui[$side + 'Stick'].IsMouseCaptured) { Show-Stick $side $x $y }
}

function Move-PointerStick($pad, $eventArgs) {
    $point = $eventArgs.GetPosition($pad)
    $x = $point.X - $pad.ActualWidth / 2
    $y = $pad.ActualHeight / 2 - $point.Y
    $radius = [Math]::Max(38.0, [Math]::Sqrt($x*$x + $y*$y))
    Show-Stick $pad.Tag ([int](32767 * $x / $radius)) ([int](32767 * $y / $radius))
}

function Reset-Input {
    $script:spinTriggerDown = $false
    $script:phoneFlags = 0
    Set-PhoneStick Left 0 0
    Set-PhoneStick Right 0 0
    foreach ($name in $script:chipDefs.Keys) { Set-Chip $name $false }
    foreach ($name in 'DpadUp','DpadLeft','DpadDown','DpadRight') { Set-Dpad $name $false }
    $script:ui.LTFill.Width = 0
    $script:ui.RTFill.Width = 0
    $script:ui.LTPercent.Text = '0%'
    $script:ui.RTPercent.Text = '0%'
}

function Set-Input([int]$flags, [int]$lt, [int]$rt, [int]$lx, [int]$ly, [int]$rx, [int]$ry) {
    if ($rt -ge 140 -and !$script:spinTriggerDown) {
        $script:spinTriggerDown = $true
        if ($script:modelVisible -and $script:scene) { $script:scene.Spin() }
    } elseif ($rt -le 80) {
        $script:spinTriggerDown = $false
    }
    $pressed = $flags -band (-bnot $script:phoneFlags)
    $script:phoneFlags = $flags
    if ($script:modelVisible -and $script:scene) {
        if ($pressed -band 0x1000) { $script:scene.Jump() }
        if ($pressed -band 0x2000) { $script:scene.Dodge() }
        if ($pressed -band 0x8000) { $script:scene.Slam() }
        if ($pressed -band 0x4000) { $script:scene.Attack() }
    }
    Set-PhoneStick Left $lx $ly
    Set-PhoneStick Right $rx $ry
    foreach ($name in $script:chipDefs.Keys) {
        Set-Chip $name (($flags -band [int]$script:chipDefs[$name]) -ne 0)
    }
    Set-Dpad 'DpadUp' (($flags -band 0x0002) -ne 0)
    Set-Dpad 'DpadLeft' (($flags -band 0x0008) -ne 0)
    Set-Dpad 'DpadDown' (($flags -band 0x0001) -ne 0)
    Set-Dpad 'DpadRight' (($flags -band 0x0004) -ne 0)

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
}

function Set-Mode([string]$mode) {
    if ($script:mode -eq $mode) { return }
    $script:mode = $mode
    $script:ui.GamepadWarning.Visibility = 'Collapsed'
    Update-ModeVisuals
    if ($script:running) { Restart-Receiver }
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

function Clear-PairingQr {
    $script:ui.QrPopup.IsOpen = $false
    $script:ui.QrButton.IsEnabled = $false
    $script:ui.PairQrImage.Source = $null
}

function Set-PairingQr([string]$matrix) {
    $rows = $matrix.Split('/')
    $n = $rows.Count
    if ($n -lt 21 -or $n -gt 177) { return }
    $size = $n + 8
    $pixels = [byte[]]::new($size * $size)
    for ($i=0; $i -lt $pixels.Length; $i++) { $pixels[$i] = 255 }
    for ($y=0; $y -lt $n; $y++) {
        if ($rows[$y].Length -ne $n -or $rows[$y] -match '[^01]') { return }
        for ($x=0; $x -lt $n; $x++) {
            if ($rows[$y][$x] -eq '1') { $pixels[($y+4)*$size+$x+4] = 0 }
        }
    }
    $script:ui.PairQrImage.Source = [Windows.Media.Imaging.BitmapSource]::Create(
        $size,$size,96,96,[Windows.Media.PixelFormats]::Gray8,$null,$pixels,$size)
    $script:ui.PairQrImage.Width = $script:ui.PairQrImage.Height = $size * 8
    $script:ui.QrButton.IsEnabled = $true
}

function Handle-ReceiverLine([string]$line) {
    if ($line.StartsWith('[PAIR-QR] ')) { Set-PairingQr $line.Substring(10); return }
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
        Clear-PairingQr
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
    Clear-PairingQr
    $script:ui.PeerText.Text = 'No phone connected'
    $script:ui.GamepadWarning.Visibility = 'Collapsed'
    Reset-Input

    $arguments = @('--ui','--qr-host',$script:address)
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
    Clear-PairingQr
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
        param($sender,$e)
        $sender.Stop()
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

foreach ($pad in $script:ui.LeftStick,$script:ui.RightStick) {
    $pad.Add_MouseLeftButtonDown({
        param($sender, $e)
        if ($sender.CaptureMouse()) { Move-PointerStick $sender $e }
        $e.Handled = $true
    })
    $pad.Add_MouseMove({
        param($sender, $e)
        if ($sender.IsMouseCaptured) { Move-PointerStick $sender $e }
    })
    $pad.Add_MouseLeftButtonUp({
        param($sender, $e)
        $sender.ReleaseMouseCapture()
    })
    $pad.Add_LostMouseCapture({
        param($sender, $e)
        $axes = $script:phoneStick[$sender.Tag]
        Show-Stick $sender.Tag $axes[0] $axes[1]
    })
}
function Initialize-PreviewControls {
    Initialize-Wukong
    if (!('WukongScene' -as [type])) { return }
    $script:ui.ChooseModel.Add_Click({ param($sender,$e) Show-CharacterPicker $sender })
    $script:ui.FullscreenChooseModel.Add_Click({ param($sender,$e) Show-CharacterPicker $sender })
    $script:ui.EnterFullscreen.Add_Click({ Set-WukongFullscreen $true })
    $script:ui.ExitFullscreen.Add_Click({ Set-WukongFullscreen $false })
    $script:ui.FullscreenHost.Add_SizeChanged({
        $hostPanel = $script:ui.FullscreenHost
        if ($script:ui.FullscreenOverlay.Visibility -eq 'Visible' -and $hostPanel.ActualHeight -gt 0) {
            # WPF uses horizontal FOV. Preserve the preview's vertical framing on wide displays.
            $aspect = $hostPanel.ActualWidth / $hostPanel.ActualHeight
            $script:ui.WukongCamera.FieldOfView = 360/[Math]::PI * [Math]::Atan(0.292 * $aspect)
        }
    })
    $script:ui.JumpButton.Add_Click({ if ($script:scene) { $script:scene.Jump() } })
    $script:ui.DodgeButton.Add_Click({ if ($script:scene) { $script:scene.Dodge() } })
    $script:ui.SpinButton.Add_Click({ if ($script:scene) { $script:scene.Spin() } })
    $script:ui.SlamButton.Add_Click({ if ($script:scene) { $script:scene.Slam() } })
    $script:ui.FightButton.Add_Click({ if ($script:scene) { $script:scene.Attack() } })
    $script:ui.ResetCamera.Add_Click({ if ($script:scene) { $script:scene.ResetCamera() } })
    $window.Add_PreviewKeyDown({
        param($sender,$e)
        if (!$script:modelVisible) { return }
        $fullscreen = $script:ui.FullscreenOverlay.Visibility -eq 'Visible'
        if ($e.Key -eq 'F11' -or ($fullscreen -and $e.Key -eq 'Escape')) {
            if (!$e.IsRepeat) { Set-WukongFullscreen (!$fullscreen) }
            $e.Handled = $true
            return
        }
        if ($script:scene -and $e.Key -in 'I','J','K','L','U') {
            if (!$e.IsRepeat) {
                switch ($e.Key) {
                    'U' { $script:scene.Spin() }
                    'I' { $script:scene.Slam() }
                    'J' { $script:scene.Jump() }
                    'K' { $script:scene.Attack() }
                    'L' { $script:scene.Dodge() }
                }
            }
            $e.Handled = $true
        }
    })
    $script:frameClock = [Diagnostics.Stopwatch]::StartNew()
    $script:frameTimer = [Windows.Threading.DispatcherTimer]::new()
    $script:frameTimer.Interval = [TimeSpan]::FromMilliseconds(33)
    $script:frameTimer.Add_Tick({
        $dt = $script:frameClock.Elapsed.TotalSeconds
        $script:frameClock.Restart()
        if ($script:scene -and $window.WindowState -ne 'Minimized') {
            $script:scene.Running = $script:ui.RunToggle.IsChecked -or ($script:phoneFlags -band 0x0200)
            $script:scene.Step($dt)
        }
    })
}

function Set-ModelVisibility([bool]$visible) {
    $script:modelVisible = $visible
    $script:ui.CharacterCard.Visibility = if ($visible) { 'Visible' } else { 'Collapsed' }
    $script:ui.ModelEyeSlash.Visibility = if ($visible) { 'Collapsed' } else { 'Visible' }
    $label = if ($visible) { 'Hide 3D model' } else { 'Show 3D model' }
    $script:ui.ModelVisibility.ToolTip = $label
    [Windows.Automation.AutomationProperties]::SetName($script:ui.ModelVisibility, $label)
    if ($visible) {
        if (!$script:frameTimer) { Initialize-PreviewControls }
        if ($script:frameTimer) {
            $script:frameClock.Restart()
            $script:frameTimer.Start()
        }
    } elseif ($script:frameTimer) {
        $script:frameTimer.Stop()
    }
}

$script:previewSettings = 'HKCU:\Software\Kishi Wi-Fi Receiver'
$preference = Get-ItemProperty -LiteralPath $script:previewSettings -Name ShowModel -ErrorAction SilentlyContinue
Set-ModelVisibility ($null -eq $preference -or $preference.ShowModel -ne 0)
$script:ui.ModelVisibility.Add_Click({
    Set-ModelVisibility (!$script:modelVisible)
    try {
        [void](New-Item -Path $script:previewSettings -Force)
        [void](New-ItemProperty -LiteralPath $script:previewSettings -Name ShowModel -Value ([int]$script:modelVisible) -PropertyType DWord -Force)
    } catch { Add-Activity 'Could not save the model visibility preference.' 'warning' }
})
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
$script:ui.QrButton.Add_Click({ $script:ui.QrPopup.IsOpen = $true })
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
    if ($script:frameTimer) { $script:frameTimer.Stop() }
    Stop-Receiver $true
})

$window.Add_Loaded({
    Start-Receiver
})

try {
    if ($StartMinimized) { $window.WindowState = 'Minimized' }
    [void]$window.ShowDialog()
} finally {
    if ($script:running -or $script:receiver) { Stop-Receiver $true }
}
