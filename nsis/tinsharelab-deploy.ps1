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
# Chrome, Edge and Coc Coc reread their registry policies on a Group Policy
# notification, not on a plain registry write, so an open browser would keep the
# old rules. RefreshPolicyEx sends that notification for the machine policies.
try {
    Add-Type -Namespace TinShareLab -Name Gp -MemberDefinition '[DllImport("userenv.dll", SetLastError = true)] public static extern bool RefreshPolicyEx(bool machine, uint options);'
    [void][TinShareLab.Gp]::RefreshPolicyEx($true, 1)
} catch {}
# Firefox only reads policies at start, so it is closed when the room is locked;
# the student reopens it under the new rules.
if ($Mode -eq 'examonly') { Get-Process -Name firefox -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
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
$keptRanges = if ((Test-Path 'D:\TinShareLab\dai.txt')) { (Get-Content 'D:\TinShareLab\dai.txt' -Raw).Trim() } else { '' }
$savedRanges = if (Test-Path $rangesPath) { (Get-Content $rangesPath -Raw).Trim() } else { $keptRanges }
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

# The machine list also lives on a data drive when there is one: lab teacher PCs
# often reset C: at every restart (Shadow Defender), and a fresh install then
# finds last session's room at once instead of scanning from nothing.
$keepDir = if ((Test-Path 'D:\') -and ([IO.DriveInfo]'D').DriveType -eq 'Fixed') { 'D:\TinShareLab' } else { $null }
function Save-Room([string[]]$machines) {
    $machines = @($machines | Where-Object { $_ } | Sort-Object -Unique)
    Set-Content -Path $machinesPath -Encoding Ascii -Value $machines
    if ($keepDir) {
        try {
            New-Item -ItemType Directory -Force -Path $keepDir | Out-Null
            Set-Content -Path (Join-Path $keepDir 'may.txt') -Encoding Ascii -Value $machines
            if (Test-Path $rangesPath) { Copy-Item -Force $rangesPath (Join-Path $keepDir 'dai.txt') }
        } catch {}
    }
}
function Get-SavedRoom {
    $paths = @($machinesPath) + @(if ($keepDir) { Join-Path $keepDir 'may.txt' })
    @($paths | Where-Object { Test-Path $_ } | ForEach-Object { Get-Content $_ } | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Sort-Object -Unique)
}
# Students NetSupport is connected to right now, by exact address.
function Get-NetSupportPeers {
    if (-not $subnet.Self) { return @() }
    $head = ($subnet.Self.Split('.')[0..1]) -join '.'
    try {
        @(Get-NetTCPConnection -State Established -ErrorAction Stop | Where-Object { $_.RemotePort -eq 5405 -or $_.LocalPort -eq 5405 } |
            ForEach-Object { $_.RemoteAddress } | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_.StartsWith("$head.") } | Sort-Object -Unique)
    } catch { @() }
}
# Which of these addresses answer on the app's port, all at once, in a second or two.
function Find-Listening([string[]]$hosts) {
    $hosts = @($hosts | Where-Object { $_ -and $_ -ne $subnet.Self } | Sort-Object -Unique)
    if (-not $hosts.Count) { return @() }
    $probe = {
        param([string]$Address)
        $client = New-Object Net.Sockets.TcpClient
        try { if ($client.ConnectAsync($Address, 11100).Wait(800) -and $client.Connected) { $Address } } catch {} finally { $client.Close() }
    }
    $pool = [runspacefactory]::CreateRunspacePool(1, 32)
    $pool.Open()
    try {
        $running = foreach ($target in $hosts) {
            $pipe = [powershell]::Create()
            $pipe.RunspacePool = $pool
            [void]$pipe.AddScript($probe).AddArgument($target)
            [pscustomobject]@{ Pipe = $pipe; Handle = $pipe.BeginInvoke() }
        }
        $found = foreach ($item in $running) {
            while (-not $item.Handle.IsCompleted) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 20 }
            $item.Pipe.EndInvoke($item.Handle)
            $item.Pipe.Dispose()
        }
        return @($found | Where-Object { $_ })
    } finally { $pool.Close() }
}

# Puts the machines into the app's "Phong may" location; an open control window
# picks the change up by itself within seconds.
function Update-Room([string[]]$machines) {
    $csv = Join-Path $env:TEMP 'tinsharelab-room.csv'
    # This machine joins the location too, so the window opens on "Phong may" by
    # itself (AutoSelectCurrentLocation) while hiding its own tile.
    $rows = @($machines) + @($subnet.Self | Where-Object { $_ })
    Set-Content -Path $csv -Encoding Ascii -Value ($rows | ForEach-Object { "$_;$_" })
    Invoke-Cli @('config', 'set', 'Master/AutoSelectCurrentLocation', 'true') | Out-Null
    Invoke-Cli @('config', 'set', 'Master/HideLocalComputer', 'true') | Out-Null
    Invoke-Cli @('config', 'set', 'Master/AutoAdjustMonitoringIconSize', 'true') | Out-Null
    Invoke-Cli @('config', 'set', 'NetworkObjectDirectory/UpdateInterval', '10') | Out-Null
    Invoke-Cli @('networkobjects', 'clear') | Out-Null
    if ($machines.Count) { Invoke-Cli @('networkobjects', 'import', $csv, 'location', $roomName, 'format', '%name%;%host%') | Out-Null }
    Remove-Item -Force -ErrorAction SilentlyContinue $csv
    Set-CliJson 'DesktopServices/PredefinedApplications' $roomApps
    Set-CliJson 'DesktopServices/PredefinedWebsites' $roomSites
}

# Opens the control window on the room; restart only when asked, so a window the
# teacher already uses stays open.
function Open-Control([switch]$Restart) {
    if (-not (Test-Path $tokenPath)) { Initialize-Teacher }
    Update-Room (Get-RoomMachines)
    $running = Get-Process -Name 'veyon-master' -ErrorAction SilentlyContinue
    if ($running -and $Restart) { $running | Stop-Process -Force -ErrorAction SilentlyContinue; $running = $null }
    if (-not $running) { Start-Process (Join-Path $installDir 'veyon-master.exe') }
}

$script:pool = $null
$script:jobs = @()
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 500

$script:openWhenDone = $false
$script:refreshWhenDone = $false
$script:quickFound = @()

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
        $hosts = @($ok | ForEach-Object { $_.Result.Host })
        if ($script:refreshWhenDone) { $hosts = @($hosts) + @($script:quickFound) }
        Save-Room $hosts
        $status.Text = "Xong: $(@(Get-RoomMachines).Count) máy trong phòng. Máy tắt hoặc chặn mạng sẽ không có trong danh sách."
        Set-Busy $false
        if ($script:refreshWhenDone) {
            $script:refreshWhenDone = $false
            try { Update-Room (Get-RoomMachines) } catch {}
        }
        if ($script:openWhenDone) {
            $script:openWhenDone = $false
            if ($ok.Count) {
                try { Open-Control -Restart } catch { [void][Windows.Forms.MessageBox]::Show("$_", 'TinShareLab Classroom', 'OK', 'Error') }
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

# ---------------------------------------------------------------- exam
# The app signs in to tinsharelab.com once with a session of its own (Google,
# through the browser), then opens, starts and ends exams there and switches the
# room's browsers to the exam page. The sealed session is readable only by
# SYSTEM and administrators, like the pairing token.
$siteUrl = 'https://tinsharelab.com'
$webSessionPath = Join-Path $dataDir 'tinsharelab-web-session'
$sessionCookieName = '__Host-tsl-session'
$featureStartApp = 'da9ca56a-b2ad-4fff-8f8a-929b2927b442'
$featureOpenWebsite = '8a11a75d-b3db-48b6-b9cb-f8422ddd5b0c'
Add-Type -AssemblyName System.Net.Http
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# Public JSON from the site, read as UTF-8 whatever the response header says.
function Get-SiteJson([string]$path) {
    $web = New-Object Net.WebClient
    $web.Encoding = [Text.Encoding]::UTF8
    try { return ConvertFrom-Json $web.DownloadString("$siteUrl$path") } finally { $web.Dispose() }
}

function Get-WebSession { if (Test-Path $webSessionPath) { (Get-Content $webSessionPath -Raw).Trim() } else { '' } }
function Save-WebSession([string]$value) {
    if ($value) {
        Set-Content -Path $webSessionPath -Encoding Ascii -NoNewline -Value $value
        & icacls.exe $webSessionPath /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' | Out-Null
    } else { Remove-Item -Force -ErrorAction SilentlyContinue $webSessionPath }
}

# One call to the site as the linked teacher. The site may hand back a renewed
# session cookie, which replaces the stored one.
function Invoke-Site([string]$method, [string]$path, [object]$body) {
    $session = Get-WebSession
    if (-not $session) { throw 'Chưa kết nối tài khoản web. Bấm "Kết nối tài khoản".' }
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.UseCookies = $false
    $handler.AllowAutoRedirect = $false
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(30)
    try {
        $message = New-Object System.Net.Http.HttpRequestMessage((New-Object System.Net.Http.HttpMethod($method)), "$siteUrl$path")
        [void]$message.Headers.TryAddWithoutValidation('Cookie', "$sessionCookieName=$session")
        [void]$message.Headers.TryAddWithoutValidation('Origin', $siteUrl)
        if ($null -ne $body) { $message.Content = New-Object System.Net.Http.StringContent((ConvertTo-Json -InputObject $body -Depth 20 -Compress), [Text.Encoding]::UTF8, 'application/json') }
        $response = $client.SendAsync($message).GetAwaiter().GetResult()
        $lines = $null
        if ($response.Headers.TryGetValues('Set-Cookie', [ref]$lines)) {
            foreach ($line in $lines) {
                if ($line -match "^$([regex]::Escape($sessionCookieName))=([^;]*);.*Max-Age=(\d+)") { Save-WebSession $(if ([int]$Matches[2] -gt 0) { $Matches[1] } else { '' }) }
            }
        }
        $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $code = [int]$response.StatusCode
        if ($code -eq 401) { Save-WebSession ''; throw 'Kết nối tài khoản đã hết hạn. Bấm "Kết nối tài khoản" lại.' }
        if ($code -eq 403) { throw 'Tài khoản này không có quyền giáo viên.' }
        if ($code -eq 409) { throw 'Phòng này đang có một buổi kiểm tra khác chưa kết thúc.' }
        if (-not $response.IsSuccessStatusCode) { throw "Web báo lỗi $code." }
        if ($text) { return (ConvertFrom-Json $text) }
    } finally { $client.Dispose() }
}

# Starts one veyon-cli feature on each machine, ten machines at a time, and
# returns how many it reached.
function Send-Feature([string[]]$hosts, [string]$feature, [object]$arguments, [string]$label) {
    $json = ConvertTo-Json -InputObject $arguments -Depth 5 -Compress
    $quoted = '"' + ($json -replace '(\\*)"', '$1$1\"') + '"'
    $ok = 0
    for ($i = 0; $i -lt $hosts.Count; $i += 10) {
        $batch = @($hosts[$i..([math]::Min($i + 9, $hosts.Count - 1))])
        $status.Text = "$label`: máy $($i + 1)-$($i + $batch.Count)/$($hosts.Count)..."
        $form.Refresh()
        $running = foreach ($target in $batch) {
            $start = New-Object Diagnostics.ProcessStartInfo $cli
            $start.Arguments = "feature start $target $feature $quoted"
            $start.UseShellExecute = $false
            $start.CreateNoWindow = $true
            [Diagnostics.Process]::Start($start)
        }
        foreach ($process in $running) {
            if ($process.WaitForExit(45000) -and $process.ExitCode -eq 0) { $ok++ } elseif (-not $process.HasExited) { $process.Kill() }
            [Windows.Forms.Application]::DoEvents()
        }
    }
    return $ok
}

function Get-RoomMachines { Get-SavedRoom }

$form.ClientSize = New-Object Drawing.Size(760, 700)
$examTitle = New-Object Windows.Forms.Label
$examTitle.Text = 'Kiểm tra'
$examTitle.Font = New-Object Drawing.Font('Segoe UI', 11, [Drawing.FontStyle]::Bold)
$examTitle.Location = New-Object Drawing.Point(16, 552)
$examTitle.Size = New-Object Drawing.Size(90, 24)
$form.Controls.Add($examTitle)
$accountLabel = New-Object Windows.Forms.Label
$accountLabel.Location = New-Object Drawing.Point(110, 554)
$accountLabel.Size = New-Object Drawing.Size(390, 24)
$form.Controls.Add($accountLabel)
$linkButton = New-Object Windows.Forms.Button
$linkButton.Text = 'Kết nối tài khoản'
$linkButton.Location = New-Object Drawing.Point(508, 548)
$linkButton.Size = New-Object Drawing.Size(236, 30)
$form.Controls.Add($linkButton)
Add-Label 'Phòng / lớp' 16 590 90
$classBox = New-Object Windows.Forms.ComboBox
$classBox.DropDownStyle = 'DropDownList'
$classBox.Location = New-Object Drawing.Point(110, 587)
$classBox.Size = New-Object Drawing.Size(250, 26)
$form.Controls.Add($classBox)
Add-Label 'Đề' 372 590 30
$presetBox = New-Object Windows.Forms.ComboBox
$presetBox.DropDownStyle = 'DropDownList'
$presetBox.Location = New-Object Drawing.Point(404, 587)
$presetBox.Size = New-Object Drawing.Size(340, 26)
$form.Controls.Add($presetBox)
$startExamButton = New-Object Windows.Forms.Button
$startExamButton.Text = 'Bắt đầu kiểm tra'
$startExamButton.Location = New-Object Drawing.Point(16, 624)
$startExamButton.Size = New-Object Drawing.Size(360, 40)
$form.Controls.Add($startExamButton)
$endExamButton = New-Object Windows.Forms.Button
$endExamButton.Text = 'Kết thúc kiểm tra'
$endExamButton.Location = New-Object Drawing.Point(384, 624)
$endExamButton.Size = New-Object Drawing.Size(360, 40)
$form.Controls.Add($endExamButton)
$examHint = New-Object Windows.Forms.Label
$examHint.Text = 'Bắt đầu: tạo buổi thi trên web (nếu phòng chưa có buổi đang mở), khóa trình duyệt chỉ vào trang thi và mở trang thi trên mọi máy.'
$examHint.Location = New-Object Drawing.Point(16, 668)
$examHint.Size = New-Object Drawing.Size(728, 30)
$form.Controls.Add($examHint)

$script:classes = @()
$script:presets = @()

function Update-ExamChoices {
    $session = Get-WebSession
    $linked = [bool]$session
    $classBox.Items.Clear(); $presetBox.Items.Clear()
    $script:classes = @(); $script:presets = @()
    if (-not $linked) { $accountLabel.Text = 'Chưa kết nối tài khoản web.'; return }
    try {
        $who = Invoke-Site 'GET' '/api/auth/session' $null
        if (-not $who.user) { Save-WebSession ''; $accountLabel.Text = 'Chưa kết nối tài khoản web.'; return }
        $accountLabel.Text = "Đã kết nối: $($who.user.email)"
        $script:classes = @((Invoke-Site 'GET' '/api/admin/classes' $null).classes | Sort-Object { $_.kind -ne 'exam' }, name)
        foreach ($item in $script:classes) { [void]$classBox.Items.Add($(if ($item.kind -eq 'exam') { "$($item.name) (phòng thi)" } else { $item.name })) }
        if ($classBox.Items.Count) { $classBox.SelectedIndex = 0 }
        $script:presets = @((Get-SiteJson '/phong-may/de-mau.json').presets)
        foreach ($item in $script:presets) {
            $each = if ($item.mode -eq 'random') { ", mỗi máy $($item.pickCount) câu riêng" } else { '' }
            [void]$presetBox.Items.Add("$($item.title) - $(@($item.problems).Count) câu$each")
        }
        [void]$presetBox.Items.Insert(0, 'Buổi đang mở trên web (đề đã chọn trên web)')
        $presetBox.SelectedIndex = $(if ($presetBox.Items.Count -gt 1) { 1 } else { 0 })
    } catch { $accountLabel.Text = "$_" }
}

# Loopback sign-in: the browser comes back to this listener with the sealed
# session and the random state it was sent with.
$script:link = $null
$linkTimer = New-Object Windows.Forms.Timer
$linkTimer.Interval = 300
function Stop-WebLink {
    $linkTimer.Stop()
    if ($script:link) { try { $script:link.Listener.Stop() } catch {}; $script:link = $null }
    $linkButton.Enabled = $true
}
$linkTimer.Add_Tick({
    $link = $script:link
    if (-not $link) { $linkTimer.Stop(); return }
    if ((Get-Date) -gt $link.Deadline) { Stop-WebLink; $accountLabel.Text = 'Hết thời gian chờ đăng nhập. Bấm "Kết nối tài khoản" lại.'; return }
    if (-not $link.Handle.IsCompleted) { return }
    $context = $link.Listener.EndGetContext($link.Handle)
    $query = $context.Request.QueryString
    $token = $query['token']
    $done = $context.Request.Url.AbsolutePath -eq '/ket-noi' -and $query['state'] -eq $link.State -and $token -match '^[\w-]+\.[\w-]+$'
    $page = if ($done) { '<p>Đã kết nối app TinShareLab Classroom. Có thể đóng tab này.</p>' } else { '<p>Liên kết không hợp lệ.</p>' }
    $bytes = [Text.Encoding]::UTF8.GetBytes("<!doctype html><meta charset=utf-8><title>TinShareLab</title><body style=""font-family:sans-serif;padding:2em"">$page<script>history.replaceState(null,'','/')</script>")
    $context.Response.StatusCode = $(if ($done) { 200 } else { 400 })
    $context.Response.ContentType = 'text/html; charset=utf-8'
    $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $context.Response.Close()
    if (-not $done) { $link.Handle = $link.Listener.BeginGetContext($null, $null); return }
    Stop-WebLink
    Save-WebSession $token
    Update-ExamChoices
    $form.Activate()
})

$linkButton.Add_Click({
    try {
        Stop-WebLink
        $bytes = New-Object byte[] 16
        [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        $state = ($bytes | ForEach-Object { $_.ToString('x2') }) -join ''
        $listener = $null
        foreach ($try in 1..10) {
            $port = Get-Random -Minimum 49152 -Maximum 65000
            $candidate = New-Object System.Net.HttpListener
            $candidate.Prefixes.Add("http://127.0.0.1:$port/")
            try { $candidate.Start(); $listener = $candidate; break } catch { $candidate.Close() }
        }
        if (-not $listener) { throw 'Không mở được cổng để nhận kết nối.' }
        $script:link = @{ Listener = $listener; State = $state; Handle = $listener.BeginGetContext($null, $null); Deadline = (Get-Date).AddMinutes(5) }
        $linkButton.Enabled = $false
        $accountLabel.Text = 'Đang chờ đăng nhập Google trên trình duyệt...'
        $linkTimer.Start()
        Start-Process "$siteUrl/phong-may/ket-noi-app/?port=$port&state=$state"
    } catch { Stop-WebLink; [void][Windows.Forms.MessageBox]::Show("$_", 'TinShareLab Classroom', 'OK', 'Error') }
})

function Set-ExamBusy([bool]$busy) {
    $startExamButton.Enabled = -not $busy
    $endExamButton.Enabled = -not $busy
    $linkButton.Enabled = -not $busy
    $form.UseWaitCursor = $busy
}

$startExamButton.Add_Click({
    try {
        if ($classBox.SelectedIndex -lt 0) { throw 'Hãy kết nối tài khoản và chọn phòng / lớp.' }
        $machines = Get-RoomMachines
        if (-not $machines.Count) { throw 'Chưa có danh sách máy. Bấm nút 2 để tìm máy trước.' }
        Set-ExamBusy $true
        $classId = $script:classes[$classBox.SelectedIndex].id
        $status.Text = 'Đang chuẩn bị buổi kiểm tra trên web...'
        $form.Refresh()
        $report = Invoke-Site 'GET' "/api/admin/lab/exam?classId=$classId" $null
        $exam = $report.exam
        if (-not $exam -or $exam.closedAt) {
            if ($presetBox.SelectedIndex -lt 1) { throw 'Phòng này chưa có buổi đang mở. Hãy chọn một đề.' }
            $preset = $script:presets[$presetBox.SelectedIndex - 1]
            $title = "$($preset.title) - $(Get-Date -Format 'dd/MM/yyyy HH:mm')"
            [void](Invoke-Site 'POST' '/api/admin/lab/exam' @{ classId = $classId; title = $title; language = $preset.language; problems = @($preset.problems); mode = $preset.mode; pickCount = [int]$preset.pickCount; durationMin = [int]$preset.durationMin; showResults = 'score' })
            $exam = (Invoke-Site 'GET' "/api/admin/lab/exam?classId=$classId" $null).exam
        }
        if (-not $exam -or -not $exam.joinCode) { throw 'Web chưa trả về mã phòng thi.' }
        if (-not $exam.startedAt) { [void](Invoke-Site 'PATCH' '/api/admin/lab/exam' @{ classId = $classId; examId = $exam.id; action = 'start' }) }
        $url = "$siteUrl/phong-may/?ma=$($exam.joinCode)"
        $locked = Send-Feature $machines $featureStartApp @{ applications = @('schtasks /run /tn TinShareLab\examonly') } 'Khóa trình duyệt'
        Start-Sleep -Seconds 2
        $opened = Send-Feature $machines $featureOpenWebsite @{ websiteUrls = @($url) } 'Mở trang thi'
        $status.Text = "Đang kiểm tra: $($exam.title). Khóa $locked/$($machines.Count) máy, mở trang thi $opened/$($machines.Count) máy."
    } catch {
        $status.Text = ''
        [void][Windows.Forms.MessageBox]::Show("$_", 'TinShareLab Classroom', 'OK', 'Error')
    } finally { Set-ExamBusy $false }
})

$endExamButton.Add_Click({
    try {
        if ($classBox.SelectedIndex -lt 0) { throw 'Hãy kết nối tài khoản và chọn phòng / lớp.' }
        if ([Windows.Forms.MessageBox]::Show('Kết thúc buổi kiểm tra và mở lại mạng cho cả phòng?', 'TinShareLab Classroom', 'YesNo', 'Question') -ne 'Yes') { return }
        Set-ExamBusy $true
        $classId = $script:classes[$classBox.SelectedIndex].id
        $exam = (Invoke-Site 'GET' "/api/admin/lab/exam?classId=$classId" $null).exam
        if ($exam -and -not $exam.closedAt) { [void](Invoke-Site 'PATCH' '/api/admin/lab/exam' @{ classId = $classId; examId = $exam.id; action = 'close' }) }
        $machines = Get-RoomMachines
        $released = Send-Feature $machines $featureStartApp @{ applications = @('schtasks /run /tn TinShareLab\release') } 'Mở mạng'
        $status.Text = "Đã kết thúc kiểm tra. Mở mạng $released/$($machines.Count) máy."
    } catch {
        $status.Text = ''
        [void][Windows.Forms.MessageBox]::Show("$_", 'TinShareLab Classroom', 'OK', 'Error')
    } finally { Set-ExamBusy $false }
})

# Like NetSupport: opening the app shows the room straight away. Machines
# known from last time and the ones NetSupport sees now are checked in a
# second or two and the control window opens on them; a full scan of the
# ranges then runs behind and adds any others to the same window.
function Start-Room {
    try {
        $status.Text = 'Đang mở phòng máy...'
        $form.Refresh()
        if (-not (Test-Path $tokenPath)) { Initialize-Teacher }
        $script:quickFound = @(Find-Listening (@(Get-SavedRoom) + @(Get-NetSupportPeers)))
        if ($script:quickFound.Count) {
            Save-Room $script:quickFound
            Open-Control
            $status.Text = "Đã mở $($script:quickFound.Count) máy. Đang dò thêm máy mới trong các dải..."
        } else { $status.Text = 'Đang dò máy trong các dải địa chỉ...' }
        Set-Busy $true
        $script:refreshWhenDone = $true
        $script:openWhenDone = -not $script:quickFound.Count
        Start-RoomJobs $null
    } catch { Set-Busy $false; $status.Text = "$_" }
}

$form.Add_Shown({ Start-Room; Update-ExamChoices })
$form.Add_FormClosed({ Stop-WebLink })

[void]$form.ShowDialog()
