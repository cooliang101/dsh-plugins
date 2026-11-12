# 微信式桌面截图（纯 PowerShell + .NET，多显示器兼容版）
#
# 实现要点：
# - per-monitor DPI aware（shcore SetProcessDpiAwareness(2)），坐标全部是物理像素；
# - 每个显示器一个独立遮罩窗体，窗体本地坐标 = 该屏截图坐标，零换算，
#   从根上避免虚拟屏负坐标/混合 DPI 造成的拖拽错位与选区错位；
# - 热键模式预创建隐藏窗体，收到触发后才抓屏并通过双缓冲绘制遮罩和标注；
# - 拖拽框选（可在任一屏开始），选区内透出原始亮度画面，实时尺寸提示；
# - 松开鼠标显示工具栏，可标注、撤销、另存为、取消或完成。
#
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File capture.ps1 -OutPath C:\path\shot.png

[CmdletBinding(DefaultParameterSetName = 'Immediate')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Immediate')][string]$OutPath,
    [Parameter(Mandatory = $true, ParameterSetName = 'Warm')][switch]$WaitForTrigger
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @"
using System.Runtime.InteropServices;
public class DpiHelper {
    [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int value);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
"@
# 2 = PROCESS_PER_MONITOR_DPI_AWARE；老系统退回 system aware
try { [void][DpiHelper]::SetProcessDpiAwareness(2) } catch { [void][DpiHelper]::SetProcessDPIAware() }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -Path (Join-Path $PSScriptRoot 'annotations.cs') -ReferencedAssemblies 'System.Drawing.dll', 'System.Windows.Forms.dll'

# UI 线程异常落盘，便于诊断（WinForms 默认弹错误对话框吞掉细节）
$script:errorLog = Join-Path $env:TEMP 'dsh-screenshot-ui-error.log'
[System.Windows.Forms.Application]::add_ThreadException({
    param($s, $e)
    [IO.File]::AppendAllText($script:errorLog, "$(Get-Date -Format o) UI: $($e.Exception)`n")
})
# 后台线程异常也落盘
[AppDomain]::CurrentDomain.add_UnhandledException({
    param($s, $e)
    [IO.File]::AppendAllText($script:errorLog, "$(Get-Date -Format o) APP: $($e.ExceptionObject)`n")
})

function Get-CaptureMonitors {
    foreach ($screen in [System.Windows.Forms.Screen]::AllScreens | Sort-Object DeviceName) {
        @{ screen = $screen; bitmap = $null; bounds = $screen.Bounds }
    }
}

function Set-CaptureBackground($form) {
    $monitor = $form.Tag
    $bounds = $monitor.bounds
    $monitor.bitmap = [System.Drawing.Bitmap]::new($bounds.Width, $bounds.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($monitor.bitmap)
    try {
        $graphics.CopyFromScreen($bounds.X, $bounds.Y, 0, 0, $bounds.Size)
    } finally {
        $graphics.Dispose()
    }
    $form.SetScreenshot($monitor.bitmap)
}

$script:selection = [System.Drawing.Rectangle]::Empty   # 虚拟屏幕坐标
$script:startPoint = $null                               # 虚拟屏幕坐标
$script:dragging = $false
$script:confirmed = $false
$script:savePath = $null
$script:annotations = $null
$script:activeTool = $null
$script:textEditor = $null
$forms = @()
$script:loop = [System.Windows.Forms.ApplicationContext]::new()
$toolbarGap = 6
$toolbarTip = [System.Windows.Forms.ToolTip]::new()
$toolbarTip.InitialDelay = 400

function New-ToolbarIcon([string]$name, [System.Drawing.Color]$color) {
    $icon = [System.Drawing.Bitmap]::new(20, 20)
    $g = [System.Drawing.Graphics]::FromImage($icon)
    $pen = [System.Drawing.Pen]::new($color, 1.65)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $pen.StartCap = $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
        $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
        switch ($name) {
            'rectangle' { $g.DrawRectangle($pen, 3, 4, 14, 12) }
            'arrow' {
                $g.DrawLine($pen, 4, 16, 16, 4)
                $g.DrawLine($pen, 10, 4, 16, 4)
                $g.DrawLine($pen, 16, 4, 16, 10)
            }
            'brush' {
                $g.DrawLine($pen, 5, 13, 14, 4)
                $g.DrawLine($pen, 8, 15, 17, 6)
                $g.DrawLine($pen, 14, 4, 17, 6)
                $g.DrawLines($pen, [System.Drawing.Point[]]@(
                    [System.Drawing.Point]::new(5, 13), [System.Drawing.Point]::new(3, 17),
                    [System.Drawing.Point]::new(8, 15), [System.Drawing.Point]::new(5, 13)))
            }
            'text' {
                $g.DrawLine($pen, 4, 4, 16, 4)
                $g.DrawLine($pen, 10, 4, 10, 16)
            }
            'mosaic' {
                $fill = [System.Drawing.SolidBrush]::new($color)
                try {
                    foreach ($y in 0..3) {
                        foreach ($x in 0..3) {
                            if (($x + $y) % 2 -eq 0) { $g.FillRectangle($fill, (2 + 4 * $x), (2 + 4 * $y), 4, 4) }
                        }
                    }
                } finally { $fill.Dispose() }
            }
            'undo' {
                $g.DrawArc($pen, 4, 6, 12, 10, 180, 270)
                $g.DrawLines($pen, [System.Drawing.Point[]]@(
                    [System.Drawing.Point]::new(3, 7), [System.Drawing.Point]::new(4, 11), [System.Drawing.Point]::new(8, 10)))
            }
            'save' {
                $g.DrawLine($pen, 10, 3, 10, 12)
                $g.DrawLines($pen, [System.Drawing.Point[]]@(
                    [System.Drawing.Point]::new(6, 8), [System.Drawing.Point]::new(10, 12), [System.Drawing.Point]::new(14, 8)))
                $g.DrawLines($pen, [System.Drawing.Point[]]@(
                    [System.Drawing.Point]::new(3, 12), [System.Drawing.Point]::new(3, 16),
                    [System.Drawing.Point]::new(17, 16), [System.Drawing.Point]::new(17, 12)))
            }
            'cancel' {
                $g.DrawLine($pen, 5, 5, 15, 15)
                $g.DrawLine($pen, 15, 5, 5, 15)
            }
            'confirm' {
                $g.DrawLines($pen, [System.Drawing.Point[]]@(
                    [System.Drawing.Point]::new(4, 10), [System.Drawing.Point]::new(8, 14), [System.Drawing.Point]::new(16, 6)))
            }
        }
    } finally {
        $pen.Dispose()
        $g.Dispose()
    }
    return $icon
}

$toolbarIcons = @{
    save = New-ToolbarIcon 'save' ([System.Drawing.Color]::FromArgb(55, 55, 55))
    cancel = New-ToolbarIcon 'cancel' ([System.Drawing.Color]::FromArgb(221, 69, 69))
    confirm = New-ToolbarIcon 'confirm' ([System.Drawing.Color]::FromArgb(7, 174, 86))
}
foreach ($tool in 'rectangle', 'arrow', 'brush', 'text', 'mosaic', 'undo') {
    $toolbarIcons[$tool] = New-ToolbarIcon $tool ([System.Drawing.Color]::FromArgb(55, 55, 55))
}

function New-SelectionBitmap([System.Drawing.Rectangle]$region) {
    $bitmap = [System.Drawing.Bitmap]::new($region.Width, $region.Height)
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.Clear([System.Drawing.Color]::Black)
            foreach ($m in $monitors) {
                $inter = [System.Drawing.Rectangle]::Intersect($region, $m.bounds)
                if ($inter.Width -le 0 -or $inter.Height -le 0) { continue }
                $source = [System.Drawing.Rectangle]::new(($inter.X - $m.bounds.X), ($inter.Y - $m.bounds.Y), $inter.Width, $inter.Height)
                $dest = [System.Drawing.Rectangle]::new(($inter.X - $region.X), ($inter.Y - $region.Y), $inter.Width, $inter.Height)
                $graphics.DrawImage($m.bitmap, $dest, $source, [System.Drawing.GraphicsUnit]::Pixel)
            }
        } finally { $graphics.Dispose() }
    } catch {
        $bitmap.Dispose()
        throw
    }
    return $bitmap
}

function Update-AnnotationUI {
    foreach ($f in $script:allForms) {
        foreach ($button in $f.Tag.toolbar.Controls) {
            if ($button.Tag -eq 'undo') {
                $button.Enabled = $null -ne $script:annotations -and $script:annotations.CanUndo
            } elseif ($button.Tag -eq $script:activeTool) {
                $button.BackColor = [System.Drawing.Color]::FromArgb(218, 244, 230)
            } else {
                $button.BackColor = $f.Tag.toolbar.BackColor
            }
        }
        $f.Cursor = if ($script:activeTool -eq 'text') { [System.Windows.Forms.Cursors]::IBeam } else { [System.Windows.Forms.Cursors]::Cross }
        $f.SetSelection($script:selection, $f.Tag.bounds, $script:annotations)
        $f.InvalidateAnnotations()
    }
}

function Get-SelectionPoint([System.Drawing.Point]$point) {
    return [System.Drawing.Point]::new(($point.X - $script:selection.X), ($point.Y - $script:selection.Y))
}

function Finish-AnnotationText([bool]$commit) {
    $editor = $script:textEditor
    if ($null -eq $editor) { return }
    $script:textEditor = $null
    if ($commit) { $script:annotations.AddText($editor.Tag, $editor.Text) }
    $font = $editor.Font
    $editor.Dispose()
    $font.Dispose()
    Update-AnnotationUI
}

function Start-AnnotationText($form, [System.Drawing.Point]$point) {
    Finish-AnnotationText $true
    $visible = [System.Drawing.Rectangle]::Intersect($script:selection, $form.Tag.bounds)
    $height = [Math]::Min(26, $visible.Height)
    $point.X = [Math]::Min($point.X, $visible.Right - [Math]::Min(48, $visible.Width))
    $point.Y = [Math]::Min($point.Y, $visible.Bottom - $height)
    $width = [Math]::Min(240, $visible.Right - $point.X)
    $origin = $form.PointToClient($point)
    $editor = [System.Windows.Forms.TextBox]::new()
    $editor.Font = [System.Drawing.Font]::new('Microsoft YaHei', 18, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
    $editor.ForeColor = [System.Drawing.Color]::FromArgb(239, 65, 65)
    $editor.AccessibleName = '截图文字标注'
    $editor.Multiline = $true
    $editor.AcceptsReturn = $true
    $editor.WordWrap = $false
    $editor.SetBounds($origin.X, $origin.Y, $width, $height)
    $editor.Tag = Get-SelectionPoint $point
    $editor.Add_LostFocus({ Finish-AnnotationText $true })
    $script:textEditor = $editor
    $form.Controls.Add($editor)
    $editor.BringToFront()
    [void]$editor.Focus()
}

function Undo-Annotation {
    Finish-AnnotationText $true
    if ($null -eq $script:annotations -or $script:annotations.Drawing) { return }
    $script:annotations.Undo()
    Update-AnnotationUI
}

function Update-Selection([System.Drawing.Point]$point) {
    $start = $script:startPoint
    $region = [System.Drawing.Rectangle]::new(
        [Math]::Min($start.X, $point.X), [Math]::Min($start.Y, $point.Y),
        [Math]::Abs($start.X - $point.X), [Math]::Abs($start.Y - $point.Y))
    if ($region -eq $script:selection -and $null -eq $script:annotations) { return }
    $script:selection = $region
    foreach ($f in $script:allForms) { $f.SetSelection($region, $f.Tag.bounds, $null) }
}

function Show-SelectionToolbar {
    $region = $script:selection
    if ($region.IsEmpty) { return }

    # 工具栏跟随选区右下角，即使选区横跨两个显示器。
    $corner = [System.Drawing.Point]::new(($region.Right - 1), ($region.Bottom - 1))
    $hostForm = $script:allForms | Where-Object { $_.Tag.bounds.Contains($corner) } | Select-Object -First 1
    if (-not $hostForm) {
        $hostForm = $script:allForms | Where-Object { $_.Tag.bounds.IntersectsWith($region) } | Select-Object -First 1
    }
    if (-not $hostForm) { return }

    $bar = $hostForm.Tag.toolbar
    $origin = $hostForm.PointToClient($corner)
    $top = $region.Top - $hostForm.Tag.bounds.Top
    $x = [Math]::Max(0, [Math]::Min($origin.X + 1 - $bar.Width, $hostForm.ClientSize.Width - $bar.Width))
    $y = $origin.Y + 1 + $toolbarGap
    if ($y + $bar.Height -gt $hostForm.ClientSize.Height) {
        $y = $top - $toolbarGap - $bar.Height
        if ($y -lt 0) { $y = $origin.Y + 1 - $toolbarGap - $bar.Height }
    }
    $y = [Math]::Max(0, [Math]::Min($y, $hostForm.ClientSize.Height - $bar.Height))
    $bar.Location = [System.Drawing.Point]::new($x, $y)
    $bar.Show()
}

function Complete-Capture {
    if ($null -ne $script:startPoint -or $null -eq $script:annotations -or $script:annotations.Drawing) { return }
    Finish-AnnotationText $true
    $script:confirmed = $true
    $script:loop.ExitThread()
}

# ---- 每个显示器一个遮罩窗体 ----
function New-CaptureForm($m) {
    $form = [CaptureOverlay]::new()
    $form.Text = 'DSH 桌面截图'
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.Bounds = $m.bounds                  # 该屏的物理像素 bounds
    $form.TopMost = $true
    $form.ShowInTaskbar = $false
    $form.StartPosition = 'Manual'
    $form.Cursor = [System.Windows.Forms.Cursors]::Cross
    $form.BackColor = [System.Drawing.Color]::Black
    $form.Hint = '拖拽框选区域 · 回车或双击完成 · Esc 取消'
    $form.Tag = $m
    $form.KeyPreview = $true

    $bar = [System.Windows.Forms.Panel]::new()
    $bar.Size = [System.Drawing.Size]::new(336, 36)
    $bar.BackColor = [System.Drawing.Color]::FromArgb(252, 252, 252)
    $bar.Add_Paint({
        param($sender, $e)
        $e.Graphics.DrawRectangle([System.Drawing.Pens]::LightGray, 0, 0, ($sender.Width - 1), ($sender.Height - 1))
        $e.Graphics.DrawLine([System.Drawing.Pens]::Gainsboro, 222, 8, 222, 27)
    })
    $bar.Cursor = [System.Windows.Forms.Cursors]::Default
    $bar.Hide()
    $m.toolbar = $bar
    $form.Controls.Add($bar)

    $selectTool = {
        param($sender, $e)
        Finish-AnnotationText $true
        $script:activeTool = if ($script:activeTool -ne $sender.Tag) { $sender.Tag }
        $sender.FindForm().ActiveControl = $null
        Update-AnnotationUI
    }
    $buttonSpecs = @(
        @{ icon = 'rectangle'; label = '矩形'; x = 4; click = $selectTool },
        @{ icon = 'arrow'; label = '箭头'; x = 40; click = $selectTool },
        @{ icon = 'brush'; label = '画笔'; x = 76; click = $selectTool },
        @{ icon = 'text'; label = '文字'; x = 112; click = $selectTool },
        @{ icon = 'mosaic'; label = '马赛克'; x = 148; click = $selectTool },
        @{ icon = 'undo'; label = '撤销 (Ctrl+Z)'; x = 184; click = {
            param($sender, $e)
            Undo-Annotation
            $sender.FindForm().ActiveControl = $null
        } },
        @{ icon = 'save'; label = '另存为'; x = 228; click = {
            param($sender, $e)
            $dialog = [System.Windows.Forms.SaveFileDialog]::new()
            try {
                $dialog.Title = '保存截图'
                $dialog.Filter = 'PNG 图片 (*.png)|*.png'
                $dialog.DefaultExt = 'png'
                $dialog.FileName = '截图-{0:yyyyMMdd-HHmmss}.png' -f (Get-Date)
                if ($dialog.ShowDialog($sender.FindForm()) -eq [System.Windows.Forms.DialogResult]::OK) {
                    $script:savePath = $dialog.FileName
                    Complete-Capture
                }
            } finally {
                $dialog.Dispose()
            }
        } },
        @{ icon = 'cancel'; label = '取消 (Esc)'; x = 264; click = { $script:loop.ExitThread() } },
        @{ icon = 'confirm'; label = '完成 (Enter)'; x = 300; click = { Complete-Capture } }
    )
    foreach ($spec in $buttonSpecs) {
        $button = [System.Windows.Forms.Button]::new()
        $button.Image = $toolbarIcons[$spec.icon]
        $button.AccessibleName = $spec.label
        $button.Tag = $spec.icon
        $button.SetBounds($spec.x, 3, 32, 30)
        $button.FlatStyle = 'Flat'
        $button.FlatAppearance.BorderSize = 0
        $button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(236, 236, 236)
        $button.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(225, 225, 225)
        $button.Cursor = [System.Windows.Forms.Cursors]::Hand
        $button.Add_Click($spec.click)
        $bar.Controls.Add($button)
        $toolbarTip.SetToolTip($button, $spec.label)
    }

    $form.Add_FormClosed({ $script:loop.ExitThread() })

    # ---- 压暗 + 选区绘制：全部用本屏本地坐标，零换算 ----
    $form.Add_MouseDown({
        param($sender, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) { $script:loop.ExitThread() }
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left -or $e.Clicks -gt 1) { return }
        $point = $sender.PointToScreen($e.Location)
        if ($script:activeTool) {
            if (-not $script:selection.Contains($point)) { return }
            if ($script:activeTool -eq 'text') {
                Start-AnnotationText $sender $point
            } else {
                $script:annotations.Begin($script:activeTool, (Get-SelectionPoint $point))
                Update-AnnotationUI
            }
            return
        }
        $script:startPoint = $point
        $script:dragging = $false
    })

    $form.Add_MouseMove({
        param($sender, $e)
        if ($null -ne $script:annotations -and $script:annotations.Drawing) {
            $script:annotations.Move((Get-SelectionPoint ($sender.PointToScreen($e.Location))))
            foreach ($f in $script:allForms) { $f.InvalidateAnnotations() }
            return
        }
        if ($null -eq $script:startPoint) { return }
        $cur = $sender.PointToScreen($e.Location)
        if (-not $script:dragging) {
            if ([Math]::Abs($cur.X - $script:startPoint.X) -lt 4 -and
                [Math]::Abs($cur.Y - $script:startPoint.Y) -lt 4) { return }
            $script:dragging = $true
            if ($null -ne $script:annotations) {
                $script:annotations.Dispose()
                $script:annotations = $null
            }
            foreach ($f in $script:allForms) { $f.Tag.toolbar.Hide() }
        }
        Update-Selection $cur
    })

    $form.Add_MouseUp({
        param($sender, $e)
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
        $point = $sender.PointToScreen($e.Location)
        if ($null -ne $script:annotations -and $script:annotations.Drawing) {
            $script:annotations.End((Get-SelectionPoint $point))
            Update-AnnotationUI
            return
        }
        if ($null -eq $script:startPoint) { return }
        if ($script:dragging) { Update-Selection $point }
        $script:startPoint = $null
        if ($script:selection.Width -lt 6 -or $script:selection.Height -lt 6 -or
            (-not $script:dragging -and -not $script:selection.Contains($point))) {
            $script:selection = [System.Drawing.Rectangle]::Empty
            if ($null -ne $script:annotations) {
                $script:annotations.Dispose()
                $script:annotations = $null
            }
            foreach ($f in $script:allForms) { $f.Tag.toolbar.Hide() }
        } elseif ($null -eq $script:annotations) {
            $script:annotations = [CaptureAnnotations]::new((New-SelectionBitmap $script:selection))
        }
        $script:dragging = $false
        Show-SelectionToolbar
        Update-AnnotationUI
    })

    $form.Add_MouseDoubleClick({
        param($sender, $e)
        if (-not $script:activeTool -and $e.Button -eq [System.Windows.Forms.MouseButtons]::Left -and
            $script:selection.Contains($sender.PointToScreen($e.Location))) {
            $script:startPoint = $null
            Complete-Capture
        }
    })

    $form.Add_MouseCaptureChanged({
        param($sender, $e)
        if (-not $sender.Capture -and $null -ne $script:annotations -and $script:annotations.Drawing) {
            $script:annotations.CancelStroke()
            Update-AnnotationUI
        }
    })

    $form.Add_KeyDown({
        param($sender, $e)
        if ($null -ne $script:textEditor -and $script:textEditor.Focused) {
            if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape -or $e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
                $e.SuppressKeyPress = $true
                Finish-AnnotationText ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter)
            }
            return
        }
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
            $e.SuppressKeyPress = $true
            $script:loop.ExitThread()
        } elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
            $e.SuppressKeyPress = $true
            Complete-Capture
        } elseif ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::Z) {
            $e.SuppressKeyPress = $true
            Undo-Annotation
        }
    })

    return $form
}

try {
    $monitors = @(Get-CaptureMonitors)
    foreach ($m in $monitors) { $forms += New-CaptureForm $m }

    if ($WaitForTrigger) {
        # 创建 HWND，但窗体保持隐藏，桌面位图在收到触发后才创建。
        foreach ($form in $forms) { $null = $form.Handle }
        [Console]::Out.WriteLine('ready')
        $request = [Console]::In.ReadLine()
        if ([string]::IsNullOrEmpty($request)) { return }
        $OutPath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($request))

        $current = @(Get-CaptureMonitors)
        $layoutChanged = $current.Count -ne $monitors.Count
        for ($i = 0; -not $layoutChanged -and $i -lt $current.Count; $i++) {
            $layoutChanged = $current[$i].screen.DeviceName -ne $monitors[$i].screen.DeviceName -or
                $current[$i].bounds -ne $monitors[$i].bounds
        }
        if ($layoutChanged) {
            foreach ($form in $forms) { $form.Dispose() }
            $forms = @()
            $monitors = $current
            foreach ($m in $monitors) { $forms += New-CaptureForm $m }
        }
    }

    $script:allForms = $forms
    foreach ($form in $forms) { Set-CaptureBackground $form }

    # 所有显示器的窗体共享消息循环，每个窗体都能接收工具栏点击。
    foreach ($form in $forms) { $form.Show() }
    $cursor = [System.Windows.Forms.Cursor]::Position
    $activeForm = $forms | Where-Object { $_.Tag.bounds.Contains($cursor) } | Select-Object -First 1
    if ($activeForm) { $activeForm.Activate() }
    [System.Windows.Forms.Application]::Run($script:loop)
    Finish-AnnotationText $false
    foreach ($form in $forms) { $form.Hide() }

    if (-not $script:confirmed) {
        [Console]::Out.WriteLine('{"ok":false,"reason":"cancelled"}')
        return
    }

    $region = $script:selection
    $script:annotations.Save($OutPath)
    if ($script:savePath -and [IO.Path]::GetFullPath($OutPath) -ne $script:savePath) {
        [IO.File]::Copy($OutPath, $script:savePath, $true)
    }

    $center = [System.Drawing.Point]::new(($region.X + [int][Math]::Floor($region.Width / 2)), ($region.Y + [int][Math]::Floor($region.Height / 2)))
    $target = $monitors | Where-Object { $_.bounds.Contains($center) } | Select-Object -First 1
    $result = @{
        ok = $true
        path = $OutPath
        x = $region.X; y = $region.Y
        width = $region.Width; height = $region.Height
        monitor = $target.screen.DeviceName
    } | ConvertTo-Json -Compress
    [Console]::Out.WriteLine($result)
} finally {
    Finish-AnnotationText $false
    foreach ($form in $forms) { $form.Dispose() }
    $script:loop.Dispose()
    if ($null -ne $script:annotations) { $script:annotations.Dispose() }
    $toolbarTip.Dispose()
    $toolbarIcons.Values | ForEach-Object { $_.Dispose() }
    foreach ($m in $monitors) {
        if ($null -ne $m.bitmap) { $m.bitmap.Dispose() }
    }
}
