# 全局热键守护：注册系统级热键，按下即调 capture.ps1 截图并复制进剪贴板。
# 由 DSH 插件在加载时启动，插件卸载时被终止。
#
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File hotkey-watch.ps1
#         -ScriptPath <capture.ps1 绝对路径> -OutDir <截图输出目录>
#         -Modifier 3 -VirtualKey 65 -HotkeyName "Ctrl+Alt+A"

param(
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [Parameter(Mandatory = $true)][int]$Modifier,
    [Parameter(Mandatory = $true)][int]$VirtualKey,
    [string]$HotkeyName = 'hotkey',
    [int]$OwnerProcessId = 0
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @"
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
public static class HotkeyWin32 {
    [DllImport("user32.dll", SetLastError = true)] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    [StructLayout(LayoutKind.Sequential)]
    public struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int ptX; public int ptY; public uint lPrivate; }
    [DllImport("user32.dll")] public static extern int GetMessageW(out MSG msg, IntPtr hWnd, uint min, uint max);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] private static extern bool PostThreadMessageW(uint threadId, uint message, IntPtr wParam, IntPtr lParam);

    public static Process WatchOwner(int processId) {
        uint threadId = GetCurrentThreadId();
        var owner = Process.GetProcessById(processId);
        owner.Exited += delegate { PostThreadMessageW(threadId, 0x0012, IntPtr.Zero, IntPtr.Zero); };
        owner.EnableRaisingEvents = true;
        return owner;
    }
}
"@

$ScriptPath = (Resolve-Path -LiteralPath $ScriptPath).ProviderPath

function Start-WarmCapture {
    $info = [System.Diagnostics.ProcessStartInfo]::new()
    $info.FileName = Join-Path $PSHOME 'powershell.exe'
    $info.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "{0}" -WaitForTrigger' -f $ScriptPath
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    try {
        return [System.Diagnostics.Process]::Start($info)
    } catch {
        [Console]::Error.WriteLine("${HotkeyName}: could not prepare capture: $_")
    }
}

$WM_HOTKEY = 0x0312
$HOTKEY_ID = 1
if (-not [HotkeyWin32]::RegisterHotKey([IntPtr]::Zero, $HOTKEY_ID, [uint32]($Modifier -bor 0x4000), [uint32]$VirtualKey)) {
    $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    [Console]::Error.WriteLine("Unable to register ${HotkeyName} (Win32 $code)")
    exit 2
}

$owner = $null
$capture = $null
try {
    if ($OwnerProcessId -gt 0) { $owner = [HotkeyWin32]::WatchOwner($OwnerProcessId) }
    [Console]::Out.WriteLine("Registered $HotkeyName")
    $capture = Start-WarmCapture
    $msg = New-Object HotkeyWin32+MSG
    while ([HotkeyWin32]::GetMessageW([ref]$msg, [IntPtr]::Zero, 0, 0) -gt 0) {
        if ($msg.message -ne $WM_HOTKEY -or $msg.wParam.ToInt64() -ne $HOTKEY_ID) { continue }
        try {
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
            $out = Join-Path $OutDir "shot-$stamp.png"
            if ($capture -and $capture.HasExited) {
                $capture.Dispose()
                $capture = $null
            }
            if (-not $capture) { $capture = Start-WarmCapture }
            if (-not $capture) { continue }
            $request = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($out))
            $capture.StandardInput.WriteLine($request)
            $capture.StandardInput.Close()
            $capture.WaitForExit()
            $exitCode = $capture.ExitCode
            $capture.Dispose()
            $capture = $null
            if (-not $owner -or -not $owner.HasExited) { $capture = Start-WarmCapture }
            if ($exitCode -ne 0) { throw "Capture exited with code $exitCode" }
            if (Test-Path -LiteralPath $out) {
                Set-Content -LiteralPath (Join-Path $OutDir 'last-screenshot.txt') -Value $out -Encoding UTF8
                # 以位图格式写入剪贴板，可直接粘贴到聊天或图像编辑器。
                $image = [System.Drawing.Bitmap]::new($out)
                try {
                    $data = [System.Windows.Forms.DataObject]::new([System.Windows.Forms.DataFormats]::Bitmap, $image)
                    [System.Windows.Forms.Clipboard]::SetDataObject($data, $true, 5, 100)
                } finally {
                    $image.Dispose()
                }
            }
        } catch {
            [Console]::Error.WriteLine("${HotkeyName}: $_")
        }
    }
} finally {
    if ($capture) {
        try { $capture.StandardInput.Close() } finally { $capture.Dispose() }
    }
    if ($owner) { $owner.Dispose() }
    [void][HotkeyWin32]::UnregisterHotKey([IntPtr]::Zero, $HOTKEY_ID)
}
