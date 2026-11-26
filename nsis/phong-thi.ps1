# Phòng thi trên máy học sinh: cửa sổ thi toàn màn hình, dòng chữ chạy luôn ở
# trên cùng, chặn chụp màn hình và sao chép từ ngoài vào. Chạy với quyền của học
# sinh (app giáo viên gọi qua "Start application"); -Stop đóng tất cả.
#   powershell -WindowStyle Hidden -ExecutionPolicy Bypass -File phong-thi.ps1 -Url https://tinsharelab.com/phong-may/?ma=XXXX
#
# Lối thoát (luôn có):
#   - Giáo viên bấm "Kết thúc" trong app (gọi -Stop).
#   - Ctrl+Alt+Shift+Q trên máy học sinh: đóng ngay cửa sổ thi, mở lại phím Windows.
#   - Tự đóng sau -Minutes phút (mặc định 120).
#   - Không bao giờ chạy trên máy giáo viên (máy có khóa riêng của app).
param([string]$Url = 'https://tinsharelab.com/phong-may/', [int]$Minutes = 120, [switch]$Stop)
$ErrorActionPreference = 'Continue'
$marker = 'tinsharelab-phong-thi'
if (-not $Stop -and (Test-Path 'C:\ProgramData\Veyon\keys\private')) { exit }

function Stop-Exam {
    Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { $_.CommandLine -match [regex]::Escape($marker) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'phong-thi\.ps1' -and $_.ProcessId -ne $PID } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}
if ($Stop) { Stop-Exam; exit }
# Only one exam window per machine.
Stop-Exam
if ($Url -notmatch '^https://tinsharelab\.com/') { $Url = 'https://tinsharelab.com/phong-may/' }

$edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
$profileDir = Join-Path $env:LOCALAPPDATA "TinShareLab\$marker"
function Start-Window {
    # A separate profile so the kiosk opens even if Edge is already running.
    Start-Process $edge -ArgumentList @("--kiosk", "`"$Url`"", '--edge-kiosk-type=fullscreen', '--no-first-run', '--disable-features=msUndersideButton', "--user-data-dir=`"$profileDir`"") -PassThru
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
public static class ExamKeys {
    const int WH_KEYBOARD_LL = 13, WM_KEYDOWN = 0x100, WM_SYSKEYDOWN = 0x104;
    delegate IntPtr Proc(int code, IntPtr wParam, IntPtr lParam);
    static Proc proc = Hook;
    static IntPtr hook = IntPtr.Zero;
    [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int id, Proc fn, IntPtr mod, uint thread);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int code, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
    [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string name);
    public static int Blocked = 0;
    public static volatile bool Quit = false;
    public static void Stop() { if (hook != IntPtr.Zero) { UnhookWindowsHookEx(hook); hook = IntPtr.Zero; } }
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr h);
    public static void Start() {
        using (var p = Process.GetCurrentProcess()) using (var m = p.MainModule) hook = SetWindowsHookEx(WH_KEYBOARD_LL, proc, GetModuleHandle(m.ModuleName), 0);
    }
    static bool Down(int key) { return (GetAsyncKeyState(key) & 0x8000) != 0; }
    static IntPtr Hook(int code, IntPtr wParam, IntPtr lParam) {
        if (code >= 0 && (wParam == (IntPtr)WM_KEYDOWN || wParam == (IntPtr)WM_SYSKEYDOWN)) {
            int vk = Marshal.ReadInt32(lParam);
            bool win = Down(0x5B) || Down(0x5C);
            // Ctrl+Alt+Shift+Q: the way out, always.
            if (vk == 0x51 && Down(0x11) && Down(0x12) && Down(0x10)) { Quit = true; Stop(); return (IntPtr)1; }
            // PrintScreen, Win+Shift+S (snip), Win+G (game bar capture), Win+PrintScreen, Win key alone.
            if (vk == 0x2C || (win && (vk == 0x53 || vk == 0x47 || vk == 0x52)) || vk == 0x5B || vk == 0x5C) { Blocked++; return (IntPtr)1; }
        }
        return CallNextHookEx(hook, code, wParam, lParam);
    }
}
public static class ExamWindow {
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int i, int v);
    // Clicks pass through the banner to the exam page, and it never takes focus.
    public static void ClickThrough(IntPtr h) { SetWindowLong(h, -20, GetWindowLong(h, -20) | 0x80000 | 0x20 | 0x08000000 | 0x80); }
}
'@

$text = '   ĐÂY LÀ BÀI KIỂM TRA TRỰC TIẾP – NGHIÊM CẤM DÙNG AI, SAO CHÉP HAY CHỤP MÀN HÌNH   •'
$screen = [Windows.Forms.Screen]::PrimaryScreen.Bounds
$banner = New-Object Windows.Forms.Form
$banner.FormBorderStyle = 'None'
$banner.ShowInTaskbar = $false
$banner.TopMost = $true
$banner.StartPosition = 'Manual'
$banner.BackColor = [Drawing.Color]::FromArgb(200, 16, 16)
$banner.Opacity = 0.92
$banner.Bounds = New-Object Drawing.Rectangle($screen.X, ($screen.Bottom - 34), $screen.Width, 34)
$label = New-Object Windows.Forms.Label
$label.AutoSize = $true
$label.ForeColor = [Drawing.Color]::White
$label.Font = New-Object Drawing.Font('Segoe UI', 13, [Drawing.FontStyle]::Bold)
$label.Text = ($text * 4)
$label.Location = New-Object Drawing.Point($screen.Width, 4)
$banner.Controls.Add($label)
$banner.Add_Shown({ [ExamWindow]::ClickThrough($banner.Handle) })

$script:window = Start-Window
$script:deadline = (Get-Date).AddMinutes([Math]::Max(1, $Minutes))
function Exit-Exam {
    $timer.Stop()
    [ExamKeys]::Stop()
    Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { $_.CommandLine -match [regex]::Escape($marker) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    $banner.Close()
}
$tick = 0
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 30
$timer.Add_Tick({
    if ([ExamKeys]::Quit -or (Get-Date) -gt $script:deadline) { Exit-Exam; return }
    # The text runs right to left, over and over.
    $x = $label.Left - 3
    if ($x -lt -($label.Width / 2)) { $x = 0 }
    $label.Left = $x
    $script:tick++
    if ($script:tick % 33 -eq 0) {
        $banner.TopMost = $false; $banner.TopMost = $true
        # Nothing copied outside the exam window can be pasted into it.
        try { [Windows.Forms.Clipboard]::Clear() } catch {}
        # Closing the exam window opens it again.
        if ($script:window -and $script:window.HasExited) { $script:window = Start-Window }
    }
})
[ExamKeys]::Start()
$timer.Start()
try { [Windows.Forms.Application]::Run($banner) } finally { [ExamKeys]::Stop() }
