# Cập nhật nhanh, không build: chép script "Cai cho ca phong" từ mã nguồn vào app đã cài.
# Dùng khi chỉ sửa nsis/tinsharelab-deploy.ps1. Sửa phần C++ thì vẫn phải build bộ cài.
# Chạy: chuột phải -> Run with PowerShell (tự xin quyền quản trị).
$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    exit
}
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'nsis\tinsharelab-deploy.ps1'
$target = 'C:\Program Files\TinShareLab Classroom\deploy\tinsharelab-deploy.ps1'
if (-not (Test-Path (Split-Path $target))) { Write-Host 'Chưa cài TinShareLab Classroom.'; Start-Sleep 5; exit 1 }
Copy-Item -Force $source $target
Write-Host "Đã cập nhật: $target ($((Get-Item $target).LastWriteTime))"
Start-Sleep 3
