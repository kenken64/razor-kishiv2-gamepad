$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$exe = Join-Path $PSScriptRoot 'target\release\kishi-receiver.exe'
$title = 'Kishi Wi-Fi Receiver'
try {
    $listener = Get-NetTCPConnection -State Listen -LocalPort 26760 -ErrorAction SilentlyContinue
    if ($listener) {
        $receiver = Get-Process -Id $listener.OwningProcess
        if ($receiver.Path -ne $exe) { throw 'Another application is using TCP port 26760.' }
        $log = Get-ChildItem -LiteralPath $env:TEMP -Filter 'kishi-*.log' -File |
            Where-Object { [Math]::Abs(($_.CreationTime - $receiver.StartTime).TotalSeconds) -lt 5 } |
            Sort-Object CreationTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    } else {
        $log = Join-Path $env:TEMP ("kishi-events-" + [Guid]::NewGuid().ToString('N') + ".log")
        $receiver = Start-Process -FilePath $exe -WindowStyle Hidden -RedirectStandardOutput $log -RedirectStandardError "$log.err" -PassThru
        Start-Sleep -Milliseconds 700
        if ($receiver.HasExited) { throw (Get-Content "$log.err" -Raw) }
    }
    $form = New-Object Windows.Forms.Form
    $form.Text = $title
    $form.ShowInTaskbar = $true
    $form.StartPosition = 'CenterScreen'
    $form.ClientSize = New-Object Drawing.Size(730,390)
    $form.MinimumSize = New-Object Drawing.Size(520,300)
    $form.BackColor = [Drawing.Color]::FromArgb(23,34,35)
    $form.ForeColor = [Drawing.Color]::White
    $header = New-Object Windows.Forms.Label
    $header.Dock = 'Top'
    $header.Height = 72
    $header.Padding = New-Object Windows.Forms.Padding(16,16,0,0)
    $header.Font = New-Object Drawing.Font('Segoe UI',18)
    $header.ForeColor = [Drawing.Color]::FromArgb(188,247,119)
    $events = New-Object Windows.Forms.ListBox
    $events.Dock = 'Fill'
    $events.HorizontalScrollbar = $true
    $events.BackColor = $form.BackColor
    $events.ForeColor = $form.ForeColor
    $events.Font = New-Object Drawing.Font('Consolas',10)
    $form.Controls.Add($events)
    $form.Controls.Add($header)
    $header.Text = 'Receiver running on TCP 26760'
    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 1000
    $refresh = {
        if ($receiver.HasExited) { $header.Text = 'Receiver stopped'; $timer.Stop(); return }
        if (!$log) { $header.Text = 'Receiver running · code in original console'; return }
        $first = Get-Content -LiteralPath $log -TotalCount 1 -ErrorAction SilentlyContinue
        if ($first -match 'Pairing code (\d{6})') { $header.Text = "Pairing code   $($Matches[1])" }
        $lines = @(foreach ($file in $log,"$log.err") {
            Get-Content -LiteralPath $file -Tail 100 -ErrorAction SilentlyContinue
        })
        $sorted = @($lines | Sort-Object)
        if (($events.Items -join "|") -ne ($sorted -join "|")) {
            $events.BeginUpdate()
            $events.Items.Clear()
            foreach ($line in $sorted) { [void]$events.Items.Add($line) }
            if ($events.Items.Count) { $events.TopIndex = $events.Items.Count-1 }
            $events.EndUpdate()
        }
    }
    $timer.Add_Tick($refresh)
    $form.Add_Shown({ & $refresh; $timer.Start(); $form.Activate() })
    [Windows.Forms.Application]::Run($form)
    $timer.Dispose()
    $form.Dispose()
} catch {
    [void][Windows.Forms.MessageBox]::Show($_.Exception.Message,$title,'OK','Error')
}
