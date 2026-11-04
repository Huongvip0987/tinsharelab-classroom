# Installs the built installer on the disposable CI machine and checks what the
# teacher and student paths rely on. Anything marked FAIL stops the release.
param([Parameter(Mandatory)][string]$Installer)
$ErrorActionPreference = 'Stop'
$failures = 0
function Report([string]$name, [bool]$ok, [string]$detail = '') {
    Write-Host ("{0} {1} {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail)
    if (-not $ok) { $script:failures++ }
}
function Note([string]$text) { Write-Host "INFO $text" }

function Wait-Port([int]$port, [int]$seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        $client = New-Object Net.Sockets.TcpClient
        try { if ($client.ConnectAsync('127.0.0.1', $port).Wait(1000) -and $client.Connected) { return $true } } catch { } finally { $client.Close() }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Call([string]$method, [string]$path, [string]$origin, [string]$body) {
    $headers = @{}
    if ($origin) { $headers.Origin = $origin }
    $arguments = @{ Uri = "http://127.0.0.1:11080/api/v1/$path"; Method = $method; Headers = $headers; UseBasicParsing = $true; TimeoutSec = 40 }
    if ($body) { $arguments.Body = $body; $arguments.ContentType = 'application/json' }
    try {
        $response = Invoke-WebRequest @arguments
        return @{ Status = [int]$response.StatusCode; Headers = $response.Headers; Content = $response.Content }
    } catch [Net.WebException] {
        if (-not $_.Exception.Response) { return @{ Status = 0; Headers = @{}; Content = "$_" } }
        return @{ Status = [int]$_.Exception.Response.StatusCode; Headers = $_.Exception.Response.Headers; Content = '' }
    }
}

$site = 'https://tinsharelab.com'
$dir = Join-Path $env:ProgramFiles 'TinShareLab Classroom'
$cli = Join-Path $dir 'veyon-wcli.exe'
$work = Join-Path $env:TEMP 'tsl-smoke'
New-Item -ItemType Directory -Force -Path $work | Out-Null
$setup = (Resolve-Path $Installer).Path

# Teacher install
$process = Start-Process -FilePath $setup -ArgumentList '/S' -Wait -PassThru
Report 'teacher install exits cleanly' ($process.ExitCode -eq 0) "code $($process.ExitCode)"
foreach ($file in 'veyon-wcli.exe', 'veyon-master.exe', 'veyon-service.exe', 'veyon-server.exe', 'plugins\webapi.dll', 'plugins\builtin-ultravnc-server.dll', 'crypto\libqca-ossl.dll', 'platforms\qwindows.dll', 'tls\qopensslbackend.dll', 'imageformats\qjpeg.dll', 'deploy\setup.exe', 'deploy\tinsharelab-deploy.ps1', 'translations\veyon_vi.qm') {
    Report "file $file" (Test-Path (Join-Path $dir $file))
}
Report 'room shortcut on the public desktop' (Test-Path (Join-Path $env:PUBLIC 'Desktop\Cai cho ca phong.lnk'))

$deployScript = Join-Path $dir 'deploy\tinsharelab-deploy.ps1'
$parseErrors = $null
[void][Management.Automation.Language.Parser]::ParseFile($deployScript, [ref]$null, [ref]$parseErrors)
Report 'room deploy script parses' (-not $parseErrors)

# The same setup the room button performs on the teacher machine
& $cli authkeys create teacher 2>&1 | Out-Host
Report 'teacher key created' ($LASTEXITCODE -eq 0) "code $LASTEXITCODE"
$publicKey = Join-Path $work 'teacher_public_key.pem'
Remove-Item -Force -ErrorAction SilentlyContinue $publicKey
& $cli authkeys export teacher/public $publicKey 2>&1 | Out-Host
Report 'teacher public key exported' (Test-Path $publicKey)
$dataDir = Join-Path $env:ProgramData 'Veyon'
Report 'private key is where the room button looks' (Test-Path (Join-Path $dataDir 'keys\private\teacher\key'))
$token = 'b' * 64
Set-Content -Path (Join-Path $dataDir 'tinsharelab-pairing-token') -Encoding Ascii -NoNewline -Value $token
& $cli config set Authentication/Method 1 2>&1 | Out-Host
& $cli config set WebAPI/HttpServerEnabled true 2>&1 | Out-Host
& $cli service stop 2>&1 | Out-Host
& $cli service start 2>&1 | Out-Host
Report 'service restarted' ($LASTEXITCODE -eq 0) "code $LASTEXITCODE"
Report 'web API is listening' (Wait-Port 11080 60)

# Student path: run the exact script the room button sends to each computer
$match = [regex]::Match((Get-Content $deployScript -Raw -Encoding UTF8), "(?s)@'\r?\n(@echo off.*?)\r?\n'@")
Report 'student install script found' $match.Success
$student = Join-Path $work 'student'
New-Item -ItemType Directory -Force -Path $student | Out-Null
Copy-Item -Force $setup (Join-Path $student 'setup.exe')
Copy-Item -Force $publicKey (Join-Path $student 'teacher_public_key.pem')
Set-Content -Path (Join-Path $student 'install.cmd') -Encoding Ascii -Value $match.Groups[1].Value
$process = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', (Join-Path $student 'install.cmd') -Wait -PassThru -WorkingDirectory $student
$outcome = if (Test-Path (Join-Path $student 'result.txt')) { (Get-Content (Join-Path $student 'result.txt') -Raw).Trim() } else { 'none' }
Report 'student install script reports ok' ($outcome -eq 'ok') "result $outcome, code $($process.ExitCode)"
Report 'public key imported for students' (Test-Path (Join-Path $dataDir 'keys\public\teacher\key'))
Report 'student port 11100 is listening' (Wait-Port 11100 60)
Report 'web API is listening after reinstall' (Wait-Port 11080 60)

# Web API rules for tinsharelab.com
$listeners = @(Get-NetTCPConnection -State Listen -LocalPort 11080 | ForEach-Object { $_.LocalAddress })
Report 'web API binds to loopback only' (($listeners.Count -gt 0) -and -not ($listeners | Where-Object { $_ -notin '127.0.0.1', '::1' })) ($listeners -join ',')
$preflight = Call 'OPTIONS' 'authentication/' $site
Report 'preflight from the site is allowed' ($preflight.Status -eq 204 -and $preflight.Headers['Access-Control-Allow-Origin'] -eq $site) "status $($preflight.Status)"
Report 'preflight allows the connection header' ("$($preflight.Headers['Access-Control-Allow-Headers'])" -match 'Connection-Uid')
Report 'preflight from another site is refused' ((Call 'OPTIONS' 'authentication/' 'https://evil.example').Status -eq 403)
Report 'request from another site is refused' ((Call 'GET' 'authentication/' 'https://evil.example').Status -eq 403)
$list = Call 'GET' 'authentication/' $site
Report 'request from the site works' ($list.Status -eq 200 -and $list.Headers['Access-Control-Allow-Origin'] -eq $site) "status $($list.Status)"
$method = '0c69b301-81b4-42d6-8fae-128cdd113314'
$wrong = Call 'POST' 'authentication/localhost' $site (@{ method = $method; credentials = @{ keyname = 'teacher'; pairingtoken = ('c' * 64) } } | ConvertTo-Json)
Report 'wrong pairing token is refused' ($wrong.Status -ne 200 -and $wrong.Status -ne 0) "status $($wrong.Status)"
$traversal = Call 'POST' 'authentication/localhost' $site (@{ method = $method; credentials = @{ keyname = '../teacher'; pairingtoken = $token } } | ConvertTo-Json)
Report 'key name cannot leave the key folder' ($traversal.Status -ne 200 -and $traversal.Status -ne 0) "status $($traversal.Status)"

# A CI machine may have no interactive desktop, so these only inform.
$right = Call 'POST' 'authentication/localhost' $site (@{ method = $method; credentials = @{ keyname = 'teacher'; pairingtoken = $token } } | ConvertTo-Json)
Note "connect with the right token: status $($right.Status)"
if ($right.Status -eq 200) {
    $uid = ($right.Content | ConvertFrom-Json).'connection-uid'
    $shot = Join-Path $work 'screen.jpg'
    try {
        Invoke-WebRequest -Uri 'http://127.0.0.1:11080/api/v1/framebuffer?format=jpeg&quality=60&width=480' -Headers @{ 'Connection-Uid' = $uid; Origin = $site } -OutFile $shot -UseBasicParsing -TimeoutSec 40
        Note "screen image: $((Get-Item $shot).Length) bytes"
    } catch { Note "screen image failed: $_" }
}

Write-Host "Failures: $failures"
if ($failures) { exit 1 }
exit 0
