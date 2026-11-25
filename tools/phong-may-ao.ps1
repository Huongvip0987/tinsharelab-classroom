# Usage (as administrator): powershell -File phong-may-ao.ps1 [-Count 30] | -Stop
# Simulated computer room on this PC: N extra Veyon servers, each pretending to
# be one student machine on port 11100 + session id (ids 11..). All show this
# PC's screen. -Stop removes them and turns multi-session back off.
param([int]$Count = 2, [switch]$Stop)
$ErrorActionPreference = 'Continue'
$log = Join-Path $PSScriptRoot 'sim-room.log'
"start $(Get-Date -Format s) count=$Count stop=$Stop" | Set-Content $log
$dir = 'C:\Program Files\TinShareLab Classroom'
$cli = Join-Path $dir 'veyon-wcli.exe'
# Servers started by this script carry the marker variable in their environment;
# stop them by the ids recorded last time.
$idsPath = Join-Path $PSScriptRoot 'sim-room.pids'
if (Test-Path $idsPath) { Get-Content $idsPath | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue } ; Remove-Item $idsPath }
if ($Stop) {
    & $cli config set Service/MultiSession false | Out-Null
    & $cli service stop | Out-Null; & $cli service start | Out-Null
    "stopped" | Add-Content $log
    exit
}
& $cli config set Service/MultiSession true | Out-Null
& $cli config set Authentication/Method 1 | Out-Null
& $cli service stop | Out-Null; & $cli service start | Out-Null
Start-Sleep -Seconds 3
$pids = foreach ($k in 1..$Count) {
    $id = 10 + $k
    $start = New-Object Diagnostics.ProcessStartInfo (Join-Path $dir 'veyon-server.exe')
    $start.UseShellExecute = $false
    $start.EnvironmentVariables['VEYON_SESSION_ID'] = "$id"
    $p = [Diagnostics.Process]::Start($start)
    $p.Id
}
$pids | Set-Content $idsPath
Start-Sleep -Seconds 6
"servers: $($pids -join ',')" | Add-Content $log
Get-NetTCPConnection -State Listen | Where-Object { $_.LocalPort -ge 11100 -and $_.LocalPort -lt 11400 } | Sort-Object LocalPort | ForEach-Object { "listen $($_.LocalAddress):$($_.LocalPort) pid $($_.OwningProcess)" } | Add-Content $log
"alive: $((Get-Process -Id $pids -ErrorAction SilentlyContinue | Measure-Object).Count)/$Count" | Add-Content $log
# The room as the control window shows it: MAY01..MAYnn on this PC's ports.
$csv = Join-Path $PSScriptRoot 'sim-room.csv'
Set-Content -Path $csv -Encoding Ascii -Value (1..$Count | ForEach-Object { 'MAY{0:D2};127.0.0.1:{1}' -f $_, (11110 + $_) })
& $cli networkobjects clear | Out-Null
& $cli networkobjects import $csv location 'Phong may ao' format '%name%;%host%' | Out-Null
& $cli config set Master/AutoSelectCurrentLocation false | Out-Null
& $cli config set Master/HideLocalComputer false | Out-Null
& $cli config set Master/AutoAdjustMonitoringIconSize true | Out-Null
"imported: $((& $cli networkobjects list) -join ' | ')" | Add-Content $log
# Open the control window for the signed-in user, kept out of screen captures so
# the 30 thumbnails do not film it over and over.
Get-Process -Name veyon-master -ErrorAction SilentlyContinue | Stop-Process -Force
$env:TINSHARELAB_SIMULATION = '1'
Start-Process (Join-Path $dir 'veyon-master.exe')
