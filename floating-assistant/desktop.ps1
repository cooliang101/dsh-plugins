$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
Add-Type -ReferencedAssemblies ([Windows.Interop.HwndSource].Assembly.Location), ([Windows.Threading.Dispatcher].Assembly.Location) -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Interop;

public static class FloatingWindow {
    private static readonly HwndSourceHook MessageHook = HandleMessage;
    public static bool Expanded { get; set; }

    public static void Attach(IntPtr hwnd) {
        HwndSource.FromHwnd(hwnd).AddHook(MessageHook);
    }

    private static IntPtr HandleMessage(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled) {
        // WM_MOUSEACTIVATE / MA_NOACTIVATE: keep the previous foreground window and deliver the click.
        if (message == 0x21 && !Expanded) {
            handled = true;
            return new IntPtr(3);
        }
        return IntPtr.Zero;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("dwmapi.dll")] public static extern int DwmFlush();
}
'@
[void][FloatingWindow]::SetProcessDpiAwarenessContext([IntPtr](-4))

$xml = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'panel.xaml') -Raw -Encoding UTF8
$window = [Windows.Markup.XamlReader]::Parse($xml)
$ui = @{}
foreach ($name in 'Handle', 'Shell', 'Refresh', 'Settings', 'Collapse', 'Tabs', 'Hero', 'CaptureArt',
    'PanelTitle', 'Summary', 'Items', 'Preferences', 'Notice', 'Actions', 'ContentScroll') {
    $ui[$name] = $window.FindName($name)
}
$script:hiddenId = $null
$script:previous = [IntPtr]::Zero
$script:hwnd = [IntPtr]::Zero
$script:monitor = ''
$script:foreground = [IntPtr]::Zero
$script:scrollPanel = $null
$script:scrollSettings = $false
$inputStream = [IO.StreamReader]::new([Console]::OpenStandardInput(), [Console]::InputEncoding)
$script:read = $inputStream.ReadLineAsync()
$script:ticks = 0

function Send($event) {
    [Console]::WriteLine((ConvertTo-Json -InputObject $event -Compress))
    [Console]::Out.Flush()
}

function Set-Placement {
    if ($script:hwnd -eq [IntPtr]::Zero -or -not $window.IsVisible) { return }
    $screen = [Windows.Forms.Screen]::AllScreens | Where-Object DeviceName -EQ $script:monitor | Select-Object -First 1
    if (-not $screen) { $screen = [Windows.Forms.Screen]::PrimaryScreen }
    $area = $screen.WorkingArea
    $dpi = [Math]::Max(96, [FloatingWindow]::GetDpiForWindow($script:hwnd)) / 96
    if ([FloatingWindow]::Expanded) {
        $window.Width = [Math]::Min(386, $area.Width / $dpi - 16)
        $window.MaxHeight = [Math]::Min(460, $area.Height / $dpi - 16)
        $window.SizeToContent = 'Height'
    } else {
        $window.SizeToContent = 'Manual'
        $window.MaxHeight = [double]::PositiveInfinity
        $window.Width = 36
        $window.Height = 84
    }
    $window.UpdateLayout()
    $rect = New-Object 'FloatingWindow+Rect'
    if (-not [FloatingWindow]::GetWindowRect($script:hwnd, [ref]$rect)) { return }
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    $inset = if ([FloatingWindow]::Expanded) { [int](8 * $dpi) } else { 0 }
    $x = [Math]::Max($area.Left, $area.Right - $width - $inset)
    $y = $area.Top + [int]([Math]::Max(0, ($area.Height - $height) * 0.40))
    if ($x -ne $rect.Left -or $y -ne $rect.Top) {
        # SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE
        [void][FloatingWindow]::SetWindowPos($script:hwnd, [IntPtr]::Zero, $x, $y, 0, 0, 0x15)
    }
}

function Set-Expanded([bool]$value, [bool]$restoreFocus = $true) {
    if ($value -eq [FloatingWindow]::Expanded) { return }
    if ($value) {
        $script:previous = [FloatingWindow]::GetForegroundWindow()
        [FloatingWindow]::Expanded = $true
        $ui.Handle.Visibility = 'Collapsed'
        $ui.Shell.Visibility = 'Visible'
        $ui.Shell.Opacity = 0
        $animation = [Windows.Media.Animation.DoubleAnimation]::new(
            0, 1, [Windows.Duration]::new([TimeSpan]::FromMilliseconds(150)))
        if ([Windows.SystemParameters]::ClientAreaAnimation) {
            $ui.Shell.BeginAnimation([Windows.UIElement]::OpacityProperty, $animation)
        } else { $ui.Shell.Opacity = 1 }
        Set-Placement
        [void]$window.Activate()
        [void]$ui.Settings.Focus()
        $script:foreground = [FloatingWindow]::GetForegroundWindow()
        $ui.ContentScroll.ScrollToTop()
        Send @{ type = 'expand' }
    } else {
        $ownsFocus = [FloatingWindow]::GetForegroundWindow() -eq $script:hwnd
        [FloatingWindow]::Expanded = $false
        $ui.Handle.Visibility = 'Visible'
        $ui.Shell.Visibility = 'Collapsed'
        Set-Placement
        if ($restoreFocus -and $ownsFocus -and $script:previous -ne $script:hwnd -and [FloatingWindow]::IsWindow($script:previous)) {
            [void][FloatingWindow]::SetForegroundWindow($script:previous)
        }
        $script:previous = [IntPtr]::Zero
        $script:foreground = [IntPtr]::Zero
        Send @{ type = 'collapse' }
    }
}

function Update-Foreground {
    if (-not [FloatingWindow]::Expanded -or $null -ne $script:hiddenId -or -not $window.IsVisible) { return }
    $current = [FloatingWindow]::GetForegroundWindow()
    if ($current -eq [IntPtr]::Zero) { return }
    if ($current -ne $script:hwnd -and $script:foreground -ne [IntPtr]::Zero -and $current -ne $script:foreground) {
        Set-Expanded $false $false
    } else {
        $script:foreground = $current
    }
}

function Add-Choice($parent, [string]$label, $event, [string]$style = 'Choice', [bool]$enabled = $true) {
    $button = [Windows.Controls.Button]::new()
    $button.Style = $window.FindResource($style)
    $button.Content = [Windows.Controls.TextBlock]@{ Text = $label; TextWrapping = 'Wrap' }
    $button.Tag = $event
    $button.IsEnabled = $enabled
    $button.Margin = '0,0,6,6'
    if ($parent -eq $ui.Actions) { $button.Margin = '0,0,0,4' }
    $button.add_Click({ param($sender, $args) Send $sender.Tag })
    [void]$parent.Children.Add($button)
}

function Add-Text($parent, [string]$text, [int]$size, [string]$color, [string]$margin) {
    $block = [Windows.Controls.TextBlock]@{
        Text = $text; FontSize = $size; Foreground = $color; Margin = $margin; TextWrapping = 'Wrap'
    }
    [void]$parent.Children.Add($block)
}

function Render($state) {
    $script:monitor = [string]$state.monitor
    $snapshot = $state.snapshot
    $panel = $state.panels | Where-Object key -EQ $state.selected | Select-Object -First 1
    $choices = @($state.panels | Where-Object enabled)
    if ($script:scrollPanel -ne $state.selected -or $script:scrollSettings -ne [bool]$state.settings) {
        $ui.ContentScroll.ScrollToTop()
        $script:scrollPanel = $state.selected
        $script:scrollSettings = [bool]$state.settings
    }
    $ui.Tabs.Children.Clear()
    $ui.Tabs.Visibility = 'Collapsed'
    $ui.Items.Children.Clear()
    $ui.Preferences.Children.Clear()
    $ui.Actions.Children.Clear()
    $ui.Refresh.IsEnabled = [bool]($panel -and -not $state.settings -and $snapshot.status -ne 'loading')
    $ui.Settings.ToolTip = if ($state.settings) { '返回面板' } else { '设置' }
    [Windows.Automation.AutomationProperties]::SetName($ui.Settings, $ui.Settings.ToolTip)
    $ui.Preferences.Visibility = if ($state.settings) { 'Visible' } else { 'Collapsed' }
    $ui.Hero.Visibility = if ($state.settings) { 'Collapsed' } else { 'Visible' }
    $ui.Notice.Visibility = if ($snapshot.message -and -not $state.settings) { 'Visible' } else { 'Collapsed' }
    $ui.Notice.Text = [string]$snapshot.message

    if ($state.settings) {
        Add-Text $ui.Preferences '面板设置' 25 '#F2F4EF' '0,0,0,10'
        foreach ($entry in $state.panels) {
            $label = if ($entry.key -eq $state.defaultPanel) { $entry.title + ' · 默认' } else { $entry.title }
            Add-Text $ui.Preferences $label 14 '#F2F4EF' '0,8,0,5'
            $row = [Windows.Controls.WrapPanel]::new()
            [void]$ui.Preferences.Children.Add($row)
            $toggle = if ($entry.enabled) { '停用' } else { '启用' }
            Add-Choice $row $toggle @{ type = 'toggle'; key = $entry.key }
            if ($entry.enabled -and $entry.key -ne $state.defaultPanel) {
                Add-Choice $row '设为默认' @{ type = 'default'; key = $entry.key }
            }
        }
        Add-Text $ui.Preferences '显示器' 16 '#F2F4EF' '0,14,0,8'
        Add-Choice $ui.Preferences '主显示器（自动）' @{ type = 'monitor'; monitor = '' } 'Choice' ($script:monitor -ne '')
        $number = 0
        foreach ($screen in [Windows.Forms.Screen]::AllScreens) {
            $number++
            $label = '显示器 {0} · {1} × {2}' -f $number, $screen.Bounds.Width, $screen.Bounds.Height
            if ($screen.DeviceName -eq $script:monitor) { $label += ' · 已选' }
            Add-Choice $ui.Preferences $label @{ type = 'monitor'; monitor = $screen.DeviceName } 'Choice' ($screen.DeviceName -ne $script:monitor)
        }
        Set-Placement
        return
    }
    if ($choices.Count -gt 1) {
        $ui.Tabs.Visibility = 'Visible'
        $navigation = [Windows.Controls.WrapPanel]::new()
        [void]$ui.Tabs.Children.Add($navigation)
        foreach ($entry in $choices) {
            $style = if ($entry.key -eq $state.selected) { 'Primary' } else { 'Choice' }
            Add-Choice $navigation $entry.title @{ type = 'select'; key = $entry.key } $style
        }
    }
    $ui.PanelTitle.Text = if ($panel) { $panel.title } else { '暂无可用面板' }
    $ui.CaptureArt.Visibility = if ($state.selected -eq 'dsh-screenshot:desktop') { 'Visible' } else { 'Collapsed' }
    $ui.Summary.Text = if (-not $panel) { '请在设置中启用面板，或安装提供面板的插件。' }
        elseif ($snapshot.status -eq 'loading') { '正在读取…' }
        elseif ($snapshot.status -eq 'error') { '暂时无法读取面板。' }
        elseif ($snapshot.summary) { $snapshot.summary }
        elseif ($snapshot.status -eq 'empty') { '暂无内容。' }
        else { '' }
    foreach ($item in $snapshot.items) {
        $row = [Windows.Controls.StackPanel]@{ Background = '#20251F'; Margin = '0,0,0,4' }
        Add-Text $row $item.text 14 '#F2F4EF' '11,8,11,6'
        if ($item.status) { Add-Text $row $item.status 12 '#AEB4AA' '11,0,11,8' }
        [void]$ui.Items.Children.Add($row)
    }
    $style = 'Primary'
    foreach ($action in $snapshot.actions) {
        Add-Choice $ui.Actions $action.label @{
            type = 'action'; id = $action.id; key = $state.selected; revision = $snapshot.revision
        } $style (-not $action.disabled)
        $style = 'Button'
    }
    if (-not $panel) { Add-Choice $ui.Actions '打开设置' @{ type = 'settings' } 'Primary' }
    Set-Placement
}

$ui.Handle.add_Click({ Set-Expanded $true })
$ui.Collapse.add_Click({ Set-Expanded $false })
$ui.Refresh.add_Click({ Send @{ type = 'refresh' } })
$ui.Settings.add_Click({ Send @{ type = 'settings' } })
$window.add_PreviewKeyDown({
    param($sender, $event)
    if ($event.Key -eq 'Escape' -and [FloatingWindow]::Expanded) {
        Set-Expanded $false
        $event.Handled = $true
    }
})
$window.add_SourceInitialized({
    $helper = [Windows.Interop.WindowInteropHelper]::new($window)
    $script:hwnd = $helper.Handle
    [FloatingWindow]::Attach($script:hwnd)
})

$timer = [Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromMilliseconds(35)
$timer.add_Tick({
    try {
        $script:ticks++
        if ($script:ticks % 28 -eq 0) { Set-Placement }
        for ($count = 0; $count -lt 12 -and $script:read.IsCompleted; $count++) {
            $line = $script:read.GetAwaiter().GetResult()
            if ($null -eq $line) { $window.Close(); return }
            $script:read = $inputStream.ReadLineAsync()
            $message = ConvertFrom-Json -InputObject $line
            switch ($message.type) {
                'render' { Render $message }
                'hide' {
                    $script:hiddenId = $message.id
                    $window.Hide()
                    [void][FloatingWindow]::DwmFlush()
                    Send @{ type = 'hidden'; id = $message.id }
                }
                'restore' {
                    if ($message.id -eq $script:hiddenId) {
                        $script:hiddenId = $null
                        $window.Show()
                        Set-Placement
                        $script:foreground = [FloatingWindow]::GetForegroundWindow()
                    }
                }
            }
        }
        Update-Foreground
    } catch {
        [Console]::Error.WriteLine($_.ToString() + ' ' + $_.ScriptStackTrace)
        $window.Close()
    }
})
$window.add_Loaded({
    Set-Placement
    Send @{ type = 'ready' }
    $timer.Start()
})
$window.add_Closed({ $timer.Stop() })
$app = [Windows.Application]::new()
[void]$app.Run($window)
