# TinShareLab Classroom: one button that sets up this teacher machine and installs
# the app on every computer in the room. It needs a Windows administrator account
# that works on those computers; it never stores the password.
$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"")
    exit
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$installDir = Split-Path $PSScriptRoot -Parent
$cli = Join-Path $installDir 'veyon-wcli.exe'
$setup = Join-Path $PSScriptRoot 'setup.exe'
$dataDir = Join-Path $env:ProgramData 'Veyon'
$publicKey = Join-Path $PSScriptRoot 'teacher_public_key.pem'
$tokenPath = Join-Path $dataDir 'tinsharelab-pairing-token'
$panelUrl = 'https://tinsharelab.com/phong-may/giao-vien/'
$machinesPath = Join-Path $dataDir 'tinsharelab-machines.txt'

function Invoke-Cli([string[]]$arguments) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $cli @arguments 2>&1 | Out-Null
    $code = $LASTEXITCODE
    $ErrorActionPreference = $previous
    return $code
}

function Initialize-Teacher {
    New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
    if (-not (Test-Path (Join-Path $dataDir 'keys\private\teacher\key'))) {
        if ((Invoke-Cli @('authkeys', 'create', 'teacher')) -ne 0) { throw 'Không tạo được khóa giáo viên.' }
    }
    Remove-Item -Force -ErrorAction SilentlyContinue $publicKey
    if ((Invoke-Cli @('authkeys', 'export', 'teacher/public', $publicKey)) -ne 0) { throw 'Không xuất được khóa công khai.' }
    if (-not (Test-Path $tokenPath)) {
        $bytes = New-Object byte[] 32
        [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        Set-Content -Path $tokenPath -Encoding Ascii -NoNewline -Value (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    # Only the service and administrators may read the pairing token.
    & icacls.exe $tokenPath /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' | Out-Null
    Invoke-Cli @('config', 'set', 'Authentication/Method', '1') | Out-Null
    Invoke-Cli @('config', 'set', 'WebAPI/HttpServerEnabled', 'true') | Out-Null
    Invoke-Cli @('service', 'stop') | Out-Null
    if ((Invoke-Cli @('service', 'start')) -ne 0) { throw 'Không khởi động lại được dịch vụ.' }
}

function Get-Subnet {
    $address = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.IPv4Address } | Select-Object -First 1
    if (-not $address) { return @{ Prefix = '192.168.1.'; Self = '' } }
    $ip = $address.IPv4Address[0].IPAddress
    return @{ Prefix = ($ip -replace '\d+$', ''); Self = $ip }
}

$installWorker = {
    param([string]$Target, [pscredential]$Credential, [string]$Setup, [string]$Key)
    $ErrorActionPreference = 'Stop'

    function Test-Port([string]$Address, [int]$Port, [int]$Timeout) {
        $client = New-Object Net.Sockets.TcpClient
        try { return $client.ConnectAsync($Address, $Port).Wait($Timeout) -and $client.Connected }
        catch { return $false }
        finally { $client.Close() }
    }

    $result = @{ Host = $Target; Found = $false; Ok = $false; Detail = '' }
    if (-not (Test-Port $Target 445 700)) {
        if (Test-Port $Target 11100 300) { $result.Found = $true; $result.Ok = $true; $result.Detail = 'Đã có app' }
        return $result
    }
    $result.Found = $true
    $drive = 'TSL' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskName = 'TinShareLabDeploy'
    $user = $Credential.UserName
    $password = $Credential.GetNetworkCredential().Password
    $stage = 'kết nối'
    try {
        New-PSDrive -Name $drive -PSProvider FileSystem -Root "\\$Target\admin$" -Credential $Credential | Out-Null
        $remote = "$($drive):\Temp\TinShareLabDeploy"
        New-Item -ItemType Directory -Force -Path $remote | Out-Null
        Remove-Item -Force -ErrorAction SilentlyContinue "$remote\result.txt"
        $stage = 'chép bộ cài'
        Copy-Item -Force $Setup "$remote\setup.exe"
        Copy-Item -Force $Key "$remote\teacher_public_key.pem"
        @'
@echo off
cd /d "%~dp0"
setup.exe /S /NoMaster /NoStartMenuFolder
set "CLI=%ProgramFiles%\TinShareLab Classroom\veyon-wcli.exe"
if not exist "%CLI%" (
  echo install_failed>result.txt
  exit /b 1
)
"%CLI%" authkeys delete teacher/public >nul 2>&1
"%CLI%" authkeys import teacher/public "%~dp0teacher_public_key.pem" || (
  echo key_failed>result.txt
  exit /b 1
)
"%CLI%" config set Authentication/Method 1
"%CLI%" service stop
"%CLI%" service start
echo ok>result.txt
'@ | Set-Content -Path "$remote\install.cmd" -Encoding Ascii

        $stage = 'chạy trình cài'
        $ErrorActionPreference = 'Continue'
        & schtasks.exe /Create /S $Target /U $user /P $password /RU SYSTEM /RL HIGHEST /SC ONCE /ST 23:59 /TN $taskName /TR 'cmd.exe /c %SystemRoot%\Temp\TinShareLabDeploy\install.cmd' /F 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'schtasks_create' }
        & schtasks.exe /Run /S $Target /U $user /P $password /TN $taskName 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'schtasks_run' }
        $ErrorActionPreference = 'Stop'

        $stage = 'chờ cài đặt'
        $deadline = (Get-Date).AddMinutes(5)
        $outcome = $null
        while ((Get-Date) -lt $deadline -and -not $outcome) {
            Start-Sleep -Seconds 3
            if (Test-Path "$remote\result.txt") { $outcome = (Get-Content "$remote\result.txt" -Raw).Trim() }
        }
        if ($outcome -ne 'ok') { throw "install:$outcome" }

        $stage = 'kiểm tra'
        $listening = $false
        for ($attempt = 0; $attempt -lt 10 -and -not $listening; $attempt++) {
            Start-Sleep -Seconds 2
            $listening = Test-Port $Target 11100 1000
        }
        if (-not $listening) { throw 'not_listening' }
        $result.Ok = $true
        $result.Detail = 'Cài xong'
    } catch {
        $message = "$_"
        $result.Detail = switch -Regex ($message) {
            'not_listening' { 'Đã cài nhưng tường lửa hoặc dịch vụ đang chặn cổng 11100'; break }
            'install:' { "Trình cài báo lỗi ($message)"; break }
            'schtasks' { 'Không chạy được lệnh từ xa: tài khoản chưa có quyền admin từ xa hoặc Task Scheduler bị chặn'; break }
            'denied|từ chối|1326|password|mật khẩu' { 'Sai tài khoản/mật khẩu hoặc không có quyền admin trên máy này'; break }
            default { "Lỗi ở bước $stage" }
        }
    } finally {
        $ErrorActionPreference = 'Continue'
        & schtasks.exe /Delete /S $Target /U $user /P $password /TN $taskName /F 2>&1 | Out-Null
        if (Get-PSDrive -Name $drive -ErrorAction SilentlyContinue) {
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue "$($drive):\Temp\TinShareLabDeploy"
            Remove-PSDrive -Name $drive -ErrorAction SilentlyContinue
        }
    }
    return $result
}

$subnet = Get-Subnet

$form = New-Object Windows.Forms.Form
$form.Text = 'TinShareLab Classroom - Cài cho cả phòng'
$form.ClientSize = New-Object Drawing.Size(760, 560)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object Drawing.Font('Segoe UI', 10)

function Add-Label([string]$text, [int]$x, [int]$y, [int]$width) {
    $label = New-Object Windows.Forms.Label
    $label.Text = $text
    $label.Location = New-Object Drawing.Point($x, $y)
    $label.Size = New-Object Drawing.Size($width, 24)
    $form.Controls.Add($label)
}
function Add-Box([string]$text, [int]$x, [int]$y, [int]$width) {
    $box = New-Object Windows.Forms.TextBox
    $box.Text = $text
    $box.Location = New-Object Drawing.Point($x, $y)
    $box.Size = New-Object Drawing.Size($width, 26)
    $form.Controls.Add($box)
    return $box
}

Add-Label 'Bật tất cả máy trong phòng, nhập tài khoản admin chung của các máy rồi bấm nút.' 16 12 720
Add-Label 'Dải địa chỉ' 16 48 90
$prefixBox = Add-Box $subnet.Prefix 110 46 130
Add-Label 'từ' 250 48 26
$fromBox = Add-Box '1' 280 46 50
Add-Label 'đến' 340 48 34
$toBox = Add-Box '254' 378 46 50
Add-Label 'Tài khoản admin' 16 84 120
$userBox = Add-Box 'Administrator' 140 82 180
Add-Label 'Mật khẩu' 335 84 70
$passwordBox = Add-Box '' 410 82 180
$passwordBox.UseSystemPasswordChar = $true

$installButton = New-Object Windows.Forms.Button
$installButton.Text = 'Tự động cài cho cả phòng'
$installButton.Location = New-Object Drawing.Point(16, 120)
$installButton.Size = New-Object Drawing.Size(260, 40)
$form.Controls.Add($installButton)

$openButton = New-Object Windows.Forms.Button
$openButton.Text = 'Mở bảng điều khiển trên web'
$openButton.Location = New-Object Drawing.Point(286, 120)
$openButton.Size = New-Object Drawing.Size(260, 40)
$form.Controls.Add($openButton)

$status = New-Object Windows.Forms.Label
$status.Location = New-Object Drawing.Point(16, 168)
$status.Size = New-Object Drawing.Size(728, 24)
$form.Controls.Add($status)

$list = New-Object Windows.Forms.ListView
$list.View = 'Details'
$list.FullRowSelect = $true
$list.Location = New-Object Drawing.Point(16, 196)
$list.Size = New-Object Drawing.Size(728, 348)
[void]$list.Columns.Add('Máy', 150)
[void]$list.Columns.Add('Kết quả', 90)
[void]$list.Columns.Add('Chi tiết', 460)
$form.Controls.Add($list)

function Open-Panel {
    if (-not (Test-Path $tokenPath)) { Initialize-Teacher }
    $token = (Get-Content $tokenPath -Raw).Trim()
    $machines = if (Test-Path $machinesPath) { ((Get-Content $machinesPath) -join ',') } else { '' }
    Start-Process "$panelUrl#ket-noi=$token&may=$machines"
}

$script:pool = $null
$script:jobs = @()
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 500

function Set-Busy([bool]$busy) {
    $installButton.Enabled = -not $busy
    $form.UseWaitCursor = $busy
}

$timer.Add_Tick({
    $pending = 0
    foreach ($job in $script:jobs) {
        if ($job.Done) { continue }
        if (-not $job.Handle.IsCompleted) { $pending++; continue }
        $job.Done = $true
        try {
            $output = $job.Pipe.EndInvoke($job.Handle)
            $result = $output[$output.Count - 1]
            if ($result.Found) {
                $row = New-Object Windows.Forms.ListViewItem($result.Host)
                [void]$row.SubItems.Add($(if ($result.Ok) { 'Thành công' } else { 'Thất bại' }))
                [void]$row.SubItems.Add($result.Detail)
                $row.ForeColor = if ($result.Ok) { [Drawing.Color]::DarkGreen } else { [Drawing.Color]::Firebrick }
                [void]$list.Items.Add($row)
            }
            $job.Result = $result
        } catch {
            $job.Result = @{ Host = $job.Host; Found = $true; Ok = $false; Detail = 'Lỗi không xác định' }
        } finally {
            $job.Pipe.Dispose()
        }
    }
    $done = $script:jobs.Count - $pending
    $status.Text = "Đã xử lý $done/$($script:jobs.Count) địa chỉ..."
    if ($pending -eq 0) {
        $timer.Stop()
        $script:pool.Close()
        $found = @($script:jobs | Where-Object { $_.Result -and $_.Result.Found })
        $ok = @($found | Where-Object { $_.Result.Ok })
        $ok | ForEach-Object { $_.Result.Host } | Set-Content -Path $machinesPath -Encoding Ascii
        $status.Text = "Xong: $($ok.Count)/$($found.Count) máy thành công. Máy tắt hoặc chặn mạng sẽ không có trong danh sách."
        Set-Busy $false
    }
})

$installButton.Add_Click({
    try {
        $from = [int]$fromBox.Text
        $to = [int]$toBox.Text
        if ($prefixBox.Text -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.$' -or $from -lt 1 -or $to -gt 254 -or $from -gt $to) { throw 'Dải địa chỉ không hợp lệ.' }
        if (-not $userBox.Text -or -not $passwordBox.Text) { throw 'Hãy nhập tài khoản và mật khẩu admin của các máy.' }
        if (-not (Test-Path $setup)) { throw 'Thiếu bộ cài. Hãy cài lại TinShareLab Classroom.' }
        Set-Busy $true
        $list.Items.Clear()
        $status.Text = 'Đang chuẩn bị máy giáo viên...'
        $form.Refresh()
        Initialize-Teacher

        $user = $userBox.Text.Trim()
        $secure = ConvertTo-SecureString $passwordBox.Text -AsPlainText -Force
        $passwordBox.Clear()
        $credential = New-Object Management.Automation.PSCredential($user, $secure)
        $script:pool = [runspacefactory]::CreateRunspacePool(1, 16)
        $script:pool.Open()
        $script:jobs = @()
        foreach ($last in $from..$to) {
            $target = "$($prefixBox.Text)$last"
            if ($target -eq $subnet.Self) { continue }
            $pipe = [powershell]::Create()
            $pipe.RunspacePool = $script:pool
            [void]$pipe.AddScript($installWorker).AddArgument($target).AddArgument($credential).AddArgument($setup).AddArgument($publicKey)
            $script:jobs += [pscustomobject]@{ Host = $target; Pipe = $pipe; Handle = $pipe.BeginInvoke(); Done = $false; Result = $null }
        }
        $timer.Start()
    } catch {
        Set-Busy $false
        $status.Text = ''
        [void][Windows.Forms.MessageBox]::Show("$_", 'TinShareLab Classroom', 'OK', 'Error')
    }
})

$openButton.Add_Click({
    try { Open-Panel } catch { [void][Windows.Forms.MessageBox]::Show("$_", 'TinShareLab Classroom', 'OK', 'Error') }
})

[void]$form.ShowDialog()
