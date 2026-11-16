# TinShareLab Classroom: sets up this teacher machine and gets the app onto the other
# computers in the room, either with a package the teacher sends through existing
# classroom software or USB, or over the network with a Windows administrator account.
# It never stores a password. -MakePackage <folder> creates the package without the window.
param([string]$MakePackage)
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
$rangesPath = Join-Path $dataDir 'tinsharelab-ranges.txt'

function Invoke-Cli([string[]]$arguments) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $cli @arguments 2>&1 | Out-Null
    $code = $LASTEXITCODE
    $ErrorActionPreference = $previous
    return $code
}

# Windows PowerShell 5.1 splits an argument that holds quotes, so a JSON value is
# passed as one hand-quoted command line (backslashes before a quote doubled).
function Set-CliJson([string]$key, [object[]]$value) {
    $json = ConvertTo-Json -InputObject $value -Compress
    $start = New-Object Diagnostics.ProcessStartInfo $cli
    $start.Arguments = "config set $key `"" + ($json -replace '(\\*)"', '$1$1\"') + '"'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($start)
    $process.WaitForExit()
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

# Prefix is every /24 inside this machine's network (up to 8), so a lab on a /22
# such as 172.16.8.0/22 is scanned whole on a fresh install with nothing typed.
function Get-Subnet {
    $address = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.IPv4Address } | Select-Object -First 1
    if (-not $address) { return @{ Prefix = '192.168.1.'; Self = '' } }
    $ip = $address.IPv4Address[0].IPAddress
    $length = [int]$address.IPv4Address[0].PrefixLength
    return @{ Prefix = (Get-NetworkRanges $ip $length); Self = $ip }
}

function Get-NetworkRanges([string]$ip, [int]$length) {
    $octets = $ip.Split('.') | ForEach-Object { [int]$_ }
    if ($length -ge 24 -or $length -lt 21) { return "$($octets[0]).$($octets[1]).$($octets[2])." }
    $count = [int][math]::Pow(2, 24 - $length)
    $start = $octets[2] - ($octets[2] % $count)
    return (($start..($start + $count - 1)) | ForEach-Object { "$($octets[0]).$($octets[1]).$_." }) -join ', '
}

# The /24s the student machines actually sit on, learned without asking anyone:
# NetSupport keeps a connection to every student (port 5405), and the ARP cache
# lists the machines on this LAN. Only addresses sharing this machine's first two
# octets count, so internet hosts never end up in the scan.
function Get-PeerRanges([string]$self) {
    if (-not $self) { return @() }
    $head = ($self.Split('.')[0..1]) -join '.'
    $inLab = { param($ip) $ip -match '^\d+\.\d+\.\d+\.\d+$' -and $ip.StartsWith("$head.") }
    $students = @()
    try { $students = @(Get-NetTCPConnection -State Established -ErrorAction Stop | Where-Object { $_.RemotePort -eq 5405 -or $_.LocalPort -eq 5405 } | ForEach-Object { $_.RemoteAddress } | Where-Object { & $inLab $_ }) } catch {}
    if ($students.Count) { return @($students | ForEach-Object { $_ -replace '\d+$', '' } | Sort-Object -Unique) }
    # No NetSupport: the busiest /24s in the ARP cache, at most four so a big
    # school network does not turn the scan into minutes.
    $neighbors = @()
    try { $neighbors = @(Get-NetNeighbor -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.State -in 'Reachable', 'Stale', 'Delay', 'Probe' } | ForEach-Object { $_.IPAddress } | Where-Object { & $inLab $_ }) } catch {}
    return @($neighbors | ForEach-Object { $_ -replace '\d+$', '' } | Group-Object | Sort-Object Count -Descending | Select-Object -First 4 | ForEach-Object { $_.Name })
}

# Runs on each student as SYSTEM through three scheduled tasks that any signed-in
# user may start, so the teacher page can switch a room with "Start application"
# (which runs as the student). netoff blocks the internet but keeps the LAN, so the
# teacher still sees the screens; examonly lets browsers open only the exam site;
# release undoes both and also runs at every boot so nobody stays locked out.
$restrictScript = @'
param([ValidateSet('netoff', 'examonly', 'release')][string]$Mode = 'release', [switch]$Register)
$ErrorActionPreference = 'Continue'
$dataHome = Join-Path $env:ProgramData 'TinShareLab'
$self = Join-Path $dataHome 'restrict.ps1'

if ($Register) {
    New-Item -ItemType Directory -Force -Path $dataHome | Out-Null
    if ($PSCommandPath -ne $self) { Copy-Item -Force $PSCommandPath $self }
    $service = New-Object -ComObject Schedule.Service
    $service.Connect()
    $root = $service.GetFolder('\')
    try { $folder = $root.GetFolder('TinShareLab') } catch { $folder = $root.CreateFolder('TinShareLab') }
    foreach ($name in 'netoff', 'examonly', 'release') {
        $task = $service.NewTask(0)
        $task.Settings.AllowDemandStart = $true
        $task.Settings.DisallowStartIfOnBatteries = $false
        $task.Settings.StopIfGoingOnBatteries = $false
        $task.Settings.ExecutionTimeLimit = 'PT5M'
        $task.Principal.UserId = 'SYSTEM'
        $task.Principal.LogonType = 5
        $task.Principal.RunLevel = 1
        if ($name -eq 'release') { [void]$task.Triggers.Create(8) }
        $action = $task.Actions.Create(0)
        $action.Path = 'powershell.exe'
        $action.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$self`" -Mode $name"
        # SYSTEM and administrators own the task; any signed-in user may only run it.
        [void]$folder.RegisterTaskDefinition($name, $task, 6, 'SYSTEM', $null, 5, 'D:(A;;FA;;;SY)(A;;FA;;;BA)(A;;GRGX;;;AU)')
    }
    exit 0
}

$group = 'TinShareLab Restrict'
# Every public IPv4 block; private ranges (the lab LAN) stay open.
$internet = '1.0.0.0-9.255.255.255', '11.0.0.0-126.255.255.255', '128.0.0.0-169.253.255.255', '169.255.0.0-172.15.255.255', '172.32.0.0-192.167.255.255', '192.169.0.0-223.255.255.255'
$examSites = 'tinsharelab.com', 'ghnefwjmhmukzyxyyvcp.supabase.co'
$chromium = 'HKLM:\SOFTWARE\Policies\Google\Chrome', 'HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'HKLM:\SOFTWARE\Policies\CocCoc\Browser'
$firefox = 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox\WebsiteFilter'

function Set-PolicyList([string]$path, [string[]]$items) {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $path
    New-Item -Force -Path $path | Out-Null
    for ($i = 0; $i -lt $items.Count; $i++) { New-ItemProperty -Force -Path $path -Name ($i + 1) -Value $items[$i] -PropertyType String | Out-Null }
}

Get-NetFirewallRule -Group $group -ErrorAction SilentlyContinue | Remove-NetFirewallRule
foreach ($path in $chromium) { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue "$path\URLBlocklist", "$path\URLAllowlist" }
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $firefox

if ($Mode -eq 'netoff') {
    New-NetFirewallRule -DisplayName 'TinShareLab - tat mang' -Group $group -Direction Outbound -Action Block -RemoteAddress $internet -Profile Any | Out-Null
}
if ($Mode -eq 'examonly') {
    foreach ($path in $chromium) {
        Set-PolicyList "$path\URLBlocklist" @('*')
        Set-PolicyList "$path\URLAllowlist" $examSites
    }
    Set-PolicyList "$firefox\Block" @('<all_urls>')
    Set-PolicyList "$firefox\Exceptions" ($examSites | ForEach-Object { "https://$_/*"; "https://*.$_/*" })
}
New-Item -ItemType Directory -Force -Path $dataHome | Out-Null
Set-Content -Path (Join-Path $dataHome 'mode.txt') -Value "$Mode $(Get-Date -Format s)"
'@

# Every step goes to install-log.txt so a failed machine says why; result.txt holds
# only the final word, which the network install waits for.
$studentInstallScript = @'
@echo off
setlocal
set "LOG=%~dp0install-log.txt"
del "%~dp0result.txt" >nul 2>&1
echo launched %date% %time% user=%username% computer=%computername% > "%LOG%"
net session >nul 2>&1 || (
  echo not_admin_requesting_uac >> "%LOG%"
  powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
cd /d "%~dp0"
echo admin_ok >> "%LOG%"
set "CLI=%ProgramFiles%\TinShareLab Classroom\veyon-cli.exe"
if not exist "%CLI%" (
  echo installing >> "%LOG%"
  start "" /wait "%~dp0setup.exe" /S /NoMaster /NoStartMenuFolder
)
if not exist "%CLI%" (
  echo install_failed >> "%LOG%"
  echo install_failed>"%~dp0result.txt"
  exit /b 1
)
if not exist "%~dp0teacher_public_key.pem" (
  echo missing_teacher_public_key.pem >> "%LOG%"
  echo key_failed>"%~dp0result.txt"
  exit /b 1
)
"%CLI%" authkeys delete teacher/public >> "%LOG%" 2>&1
set N=0
:retry
set /a N+=1
"%CLI%" authkeys import teacher/public "%~dp0teacher_public_key.pem" >> "%LOG%" 2>&1 && goto imported
if %N% lss 5 (
  timeout /t 3 /nobreak >nul
  goto retry
)
echo key_failed >> "%LOG%"
echo key_failed>"%~dp0result.txt"
exit /b 1
:imported
"%CLI%" config set Authentication/Method 1 >> "%LOG%" 2>&1
netsh advfirewall firewall delete rule name="TinShareLab 11100" >nul 2>&1
netsh advfirewall firewall add rule name="TinShareLab 11100" dir=in action=allow protocol=TCP localport=11100 >> "%LOG%" 2>&1
"%CLI%" service stop >> "%LOG%" 2>&1
"%CLI%" service start >> "%LOG%" 2>&1
if exist "%~dp0restrict.ps1" (
  echo registering_restrict_tasks >> "%LOG%"
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0restrict.ps1" -Register >> "%LOG%" 2>&1
  schtasks /query /tn "TinShareLab\examonly" >nul 2>&1 || echo restrict_tasks_missing >> "%LOG%"
)
echo ok >> "%LOG%"
echo ok>"%~dp0result.txt"
'@

function New-StudentPackage([string]$folder) {
    if (-not (Test-Path $setup)) { throw 'Thiếu bộ cài. Hãy cài lại TinShareLab Classroom.' }
    Initialize-Teacher
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    Copy-Item -Force $setup (Join-Path $folder 'setup.exe')
    Copy-Item -Force $publicKey (Join-Path $folder 'teacher_public_key.pem')
    Set-Content -Path (Join-Path $folder 'install.cmd') -Encoding Ascii -Value $studentInstallScript
    Set-Content -Path (Join-Path $folder 'restrict.ps1') -Encoding UTF8 -Value $restrictScript
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $folder 'result.txt'), (Join-Path $folder 'install-log.txt')
}

# The room can span several /24 ranges (e.g. 172.16.9. and 172.16.11.), so the box
# takes a comma-separated list. Leading zeros are dropped so "172.16.09." still works.
function Get-Prefixes([string]$text) {
    $prefixes = @()
    foreach ($item in ($text -split '[,;\s]+' | Where-Object { $_ })) {
        $parts = $item.Trim('.').Split('.')
        if ($parts.Count -ne 3) { throw "Dải địa chỉ không hợp lệ: $item (ví dụ đúng: 172.16.11.)" }
        $octets = foreach ($part in $parts) {
            if ($part -notmatch '^\d{1,3}$' -or [int]$part -gt 255) { throw "Dải địa chỉ không hợp lệ: $item" }
            [int]$part
        }
        $prefix = ($octets -join '.') + '.'
        if ($prefixes -notcontains $prefix) { $prefixes += $prefix }
    }
    if (-not $prefixes.Count) { throw 'Hãy nhập ít nhất một dải địa chỉ, ví dụ 172.16.11.' }
    return $prefixes
}

if ($MakePackage) {
    New-StudentPackage $MakePackage
    exit 0
}

$installWorker = {
    param([string]$Target, [object]$Credential, [string]$Setup, [string]$Key, [string]$InstallScript, [string]$RestrictScript)
    $ErrorActionPreference = 'Stop'

    function Test-Port([string]$Address, [int]$Port, [int]$Timeout) {
        $client = New-Object Net.Sockets.TcpClient
        try { return $client.ConnectAsync($Address, $Port).Wait($Timeout) -and $client.Connected }
        catch { return $false }
        finally { $client.Close() }
    }

    $result = @{ Host = $Target; Found = $false; Ok = $false; Detail = '' }
    if (-not $Credential) {
        if (Test-Port $Target 11100 900) { $result.Found = $true; $result.Ok = $true; $result.Detail = 'Đã có app' }
        return $result
    }
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
        Set-Content -Path "$remote\install.cmd" -Encoding Ascii -Value $InstallScript
        Set-Content -Path "$remote\restrict.ps1" -Encoding UTF8 -Value $RestrictScript

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

Add-Label 'Máy con không có mật khẩu: bấm nút 1, gửi gói qua NetSupport hoặc USB, chạy xong thì bấm nút 2.' 16 12 720
# Saved ranges, this network's ranges and the ranges NetSupport students are on,
# merged, so the teacher never types an address.
$savedRanges = if (Test-Path $rangesPath) { (Get-Content $rangesPath -Raw).Trim() } else { '' }
$startRanges = try { (Get-Prefixes ((@($savedRanges, $subnet.Prefix) + (Get-PeerRanges $subnet.Self)) -join ',')) -join ', ' } catch { $subnet.Prefix }
Add-Label 'Dải địa chỉ' 16 48 90
$prefixBox = Add-Box $startRanges 110 46 250
Add-Label 'từ' 370 48 26
$fromBox = Add-Box '1' 400 46 50
Add-Label 'đến' 460 48 34
$toBox = Add-Box '254' 498 46 50
Add-Label 'Nhiều dải: dùng dấu phẩy' 556 48 190
Add-Label 'Tài khoản admin' 16 84 120
$userBox = Add-Box 'Administrator' 140 82 180
Add-Label 'Mật khẩu' 335 84 70
$passwordBox = Add-Box '' 410 82 180
$passwordBox.UseSystemPasswordChar = $true

$packageButton = New-Object Windows.Forms.Button
$packageButton.Text = '1. Tạo gói cài cho máy con'
$packageButton.Location = New-Object Drawing.Point(16, 120)
$packageButton.Size = New-Object Drawing.Size(236, 40)
$form.Controls.Add($packageButton)

$openButton = New-Object Windows.Forms.Button
$openButton.Text = '2. Tìm máy, mở bảng điều khiển'
$openButton.Location = New-Object Drawing.Point(262, 120)
$openButton.Size = New-Object Drawing.Size(236, 40)
$form.Controls.Add($openButton)

$installButton = New-Object Windows.Forms.Button
$installButton.Text = 'Cài qua mạng (cần mật khẩu)'
$installButton.Location = New-Object Drawing.Point(508, 120)
$installButton.Size = New-Object Drawing.Size(236, 40)
$form.Controls.Add($installButton)

$examButton = New-Object Windows.Forms.Button
$examButton.Text = 'Lấy đề thi trên web'
$examButton.Location = New-Object Drawing.Point(508, 164)
$examButton.Size = New-Object Drawing.Size(236, 28)
$form.Controls.Add($examButton)

$status = New-Object Windows.Forms.Label
$status.Location = New-Object Drawing.Point(16, 168)
$status.Size = New-Object Drawing.Size(484, 24)
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

# The room is controlled from the app's own window (veyon-master): the machines
# just found become its "Phong may" location, and the room switches are preset
# under "Start application" / "Open website". The web page is only for exams.
$roomName = 'Phong may'
$roomApps = @(
    @{ Type = 1; Name = 'Tắt mạng'; Path = 'schtasks /run /tn TinShareLab\netoff'; Uid = '{6f1c2a10-7d3b-4c8e-9a51-1b2c3d4e5f01}' },
    @{ Type = 1; Name = 'Chỉ trang kiểm tra'; Path = 'schtasks /run /tn TinShareLab\examonly'; Uid = '{6f1c2a10-7d3b-4c8e-9a51-1b2c3d4e5f02}' },
    @{ Type = 1; Name = 'Mở mạng'; Path = 'schtasks /run /tn TinShareLab\release'; Uid = '{6f1c2a10-7d3b-4c8e-9a51-1b2c3d4e5f03}' }
)
$roomSites = @(
    @{ Type = 2; Name = 'Trang kiểm tra'; Path = 'https://tinsharelab.com/phong-may/'; Uid = '{6f1c2a10-7d3b-4c8e-9a51-1b2c3d4e5f11}' }
)

function Open-Control {
    if (-not (Test-Path $tokenPath)) { Initialize-Teacher }
    $machines = @(if (Test-Path $machinesPath) { Get-Content $machinesPath | Where-Object { $_.Trim() } })
    $csv = Join-Path $env:TEMP 'tinsharelab-room.csv'
    # This machine joins the location too, so the window opens on "Phong may" by
    # itself (AutoSelectCurrentLocation) while hiding its own tile.
    $rows = @($machines) + @($subnet.Self | Where-Object { $_ })
    Set-Content -Path $csv -Encoding Ascii -Value ($rows | ForEach-Object { "$_;$_" })
    Invoke-Cli @('config', 'set', 'Master/AutoSelectCurrentLocation', 'true') | Out-Null
    Invoke-Cli @('config', 'set', 'Master/HideLocalComputer', 'true') | Out-Null
    Invoke-Cli @('config', 'set', 'Master/AutoAdjustMonitoringIconSize', 'true') | Out-Null
    Invoke-Cli @('networkobjects', 'clear') | Out-Null
    if ($machines.Count) { Invoke-Cli @('networkobjects', 'import', $csv, 'location', $roomName, 'format', '%name%;%host%') | Out-Null }
    Remove-Item -Force -ErrorAction SilentlyContinue $csv
    Set-CliJson 'DesktopServices/PredefinedApplications' $roomApps
    Set-CliJson 'DesktopServices/PredefinedWebsites' $roomSites
    Get-Process -Name 'veyon-master' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Process (Join-Path $installDir 'veyon-master.exe')
}

$script:pool = $null
$script:jobs = @()
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 500

$script:openWhenDone = $false

function Set-Busy([bool]$busy) {
    $installButton.Enabled = -not $busy
    $packageButton.Enabled = -not $busy
    $openButton.Enabled = -not $busy
    $form.UseWaitCursor = $busy
}

function Start-RoomJobs([object]$credential) {
    $from = [int]$fromBox.Text
    $to = [int]$toBox.Text
    if ($from -lt 1 -or $to -gt 254 -or $from -gt $to) { throw 'Khoảng "từ ... đến" phải nằm trong 1-254.' }
    $prefixes = Get-Prefixes $prefixBox.Text
    $prefixBox.Text = $prefixes -join ', '
    Set-Content -Path $rangesPath -Encoding UTF8 -Value $prefixBox.Text
    $list.Items.Clear()
    $script:pool = [runspacefactory]::CreateRunspacePool(1, 32)
    $script:pool.Open()
    $script:jobs = @()
    foreach ($prefix in $prefixes) {
        foreach ($last in $from..$to) {
            $target = "$prefix$last"
            if ($target -eq $subnet.Self) { continue }
            $pipe = [powershell]::Create()
            $pipe.RunspacePool = $script:pool
            [void]$pipe.AddScript($installWorker).AddArgument($target).AddArgument($credential).AddArgument($setup).AddArgument($publicKey).AddArgument($studentInstallScript).AddArgument($restrictScript)
            $script:jobs += [pscustomobject]@{ Host = $target; Pipe = $pipe; Handle = $pipe.BeginInvoke(); Done = $false; Result = $null }
        }
    }
    $timer.Start()
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
        Set-Content -Path $machinesPath -Encoding Ascii -Value @($ok | ForEach-Object { $_.Result.Host })
        $status.Text = "Xong: $($ok.Count)/$($found.Count) máy thành công. Máy tắt hoặc chặn mạng sẽ không có trong danh sách."
        Set-Busy $false
        if ($script:openWhenDone) {
            $script:openWhenDone = $false
            if ($ok.Count) {
                try { Open-Control } catch { [void][Windows.Forms.MessageBox]::Show("$_", 'TinShareLab Classroom', 'OK', 'Error') }
            } else {
                [void][Windows.Forms.MessageBox]::Show('Chưa thấy máy nào đã cài. Hãy kiểm tra máy con đã chạy install.cmd, đã bật và cùng dải địa chỉ.', 'TinShareLab Classroom', 'OK', 'Warning')
            }
        }
    }
})

$packageButton.Add_Click({
    try {
        Set-Busy $true
        $status.Text = 'Đang tạo gói cài...'
        $form.Refresh()
        $folder = Join-Path ([Environment]::GetFolderPath('Desktop')) 'TinShareLab-May-Con'
        New-StudentPackage $folder
        $status.Text = "Đã tạo gói: $folder"
        Start-Process explorer.exe $folder
        [void][Windows.Forms.MessageBox]::Show("Dùng NetSupport hoặc USB chép cả thư mục này sang các máy con rồi chạy install.cmd trên đó.`n`nSau khi các máy chạy xong khoảng 1-2 phút, bấm nút 2 để tìm máy và mở web.", 'TinShareLab Classroom', 'OK', 'Information')
    } catch {
        $status.Text = ''
        [void][Windows.Forms.MessageBox]::Show("$_", 'TinShareLab Classroom', 'OK', 'Error')
    } finally {
        Set-Busy $false
    }
})

$installButton.Add_Click({
    try {
        if (-not $userBox.Text -or -not $passwordBox.Text) { throw 'Máy con không có mật khẩu thì dùng nút 1. Nút này cần tài khoản và mật khẩu admin của các máy.' }
        if (-not (Test-Path $setup)) { throw 'Thiếu bộ cài. Hãy cài lại TinShareLab Classroom.' }
        Set-Busy $true
        $status.Text = 'Đang chuẩn bị máy giáo viên...'
        $form.Refresh()
        Initialize-Teacher

        $user = $userBox.Text.Trim()
        $secure = ConvertTo-SecureString $passwordBox.Text -AsPlainText -Force
        $passwordBox.Clear()
        Start-RoomJobs (New-Object Management.Automation.PSCredential($user, $secure))
    } catch {
        Set-Busy $false
        $status.Text = ''
        [void][Windows.Forms.MessageBox]::Show("$_", 'TinShareLab Classroom', 'OK', 'Error')
    }
})

$examButton.Add_Click({ Start-Process $panelUrl })

$openButton.Add_Click({
    try {
        Set-Busy $true
        $status.Text = 'Đang tìm máy đã cài...'
        $form.Refresh()
        if (-not (Test-Path $tokenPath)) { Initialize-Teacher }
        $script:openWhenDone = $true
        Start-RoomJobs $null
    } catch {
        $script:openWhenDone = $false
        Set-Busy $false
        $status.Text = ''
        [void][Windows.Forms.MessageBox]::Show("$_", 'TinShareLab Classroom', 'OK', 'Error')
    }
})

[void]$form.ShowDialog()
