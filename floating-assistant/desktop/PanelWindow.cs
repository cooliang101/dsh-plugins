using System;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using Screen = System.Windows.Forms.Screen;

internal sealed class PanelWindow
{
    private readonly Window window;
    private readonly Action<object> send;
    private readonly DispatcherTimer timer;
    private readonly HwndSourceHook windowHook;
    private readonly Button handle, refresh, settings;
    private readonly Border shell, hero, captureArt;
    private readonly ScrollViewer scroll;
    private readonly StackPanel tabs, items, preferences, actions;
    private readonly TextBlock title, summary, notice;
    private IntPtr hwnd, previous, foreground;
    private bool expanded, scrollSettings;
    private long? hiddenId;
    private string monitor = "", scrollPanel;
    private int ticks;

    internal PanelWindow(Window window, Action<object> send)
    {
        this.window = window;
        this.send = send;
        handle = Find<Button>("Handle");
        refresh = Find<Button>("Refresh");
        settings = Find<Button>("Settings");
        shell = Find<Border>("Shell");
        hero = Find<Border>("Hero");
        captureArt = Find<Border>("CaptureArt");
        scroll = Find<ScrollViewer>("ContentScroll");
        tabs = Find<StackPanel>("Tabs");
        items = Find<StackPanel>("Items");
        preferences = Find<StackPanel>("Preferences");
        actions = Find<StackPanel>("Actions");
        title = Find<TextBlock>("PanelTitle");
        summary = Find<TextBlock>("Summary");
        notice = Find<TextBlock>("Notice");

        handle.Click += (sender, e) => SetExpanded(true);
        Find<Button>("Collapse").Click += (sender, e) => SetExpanded(false);
        refresh.Click += (sender, e) => send(new { type = "refresh" });
        settings.Click += (sender, e) => send(new { type = "settings" });
        window.PreviewKeyDown += (sender, e) =>
        {
            if (e.Key != Key.Escape || !expanded) return;
            SetExpanded(false);
            e.Handled = true;
        };
        windowHook = HandleWindowMessage;
        window.SourceInitialized += (sender, e) =>
        {
            hwnd = new WindowInteropHelper(window).Handle;
            HwndSource.FromHwnd(hwnd).AddHook(windowHook);
            NativeWindow.MakeToolWindow(hwnd);
        };
        timer = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromMilliseconds(35) };
        timer.Tick += (sender, e) =>
        {
            if (++ticks % 28 == 0) Place();
            UpdateForeground();
        };
        window.Closed += (sender, e) => timer.Stop();
    }

    internal void Ready()
    {
        Place();
        send(new { type = "ready" });
        timer.Start();
    }

    internal void Receive(HostMessage message)
    {
        switch (message.Type)
        {
            case "render":
                Render(message);
                break;
            case "hide":
                hiddenId = message.Id;
                window.Hide();
                NativeWindow.DwmFlush();
                send(new { type = "hidden", id = message.Id });
                break;
            case "restore":
                if (hiddenId != message.Id) return;
                hiddenId = null;
                window.Show();
                Place();
                foreground = NativeWindow.GetForegroundWindow();
                break;
        }
    }

    private T Find<T>(string name) where T : FrameworkElement
    {
        return (T)window.FindName(name);
    }

    private IntPtr HandleWindowMessage(IntPtr windowHandle, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        // WM_MOUSEACTIVATE / MA_NOACTIVATE keeps the previous foreground window and delivers the click.
        if (message != 0x21 || expanded) return IntPtr.Zero;
        handled = true;
        return new IntPtr(3);
    }

    private void Place()
    {
        if (hwnd == IntPtr.Zero || !window.IsVisible) return;
        var screen = Screen.AllScreens.FirstOrDefault(candidate => candidate.DeviceName == monitor) ?? Screen.PrimaryScreen;
        if (screen == null) return;
        var area = screen.WorkingArea;
        double dpi = Math.Max(96, NativeWindow.GetDpiForWindow(hwnd)) / 96.0;
        if (expanded)
        {
            window.Width = Math.Min(386, Math.Max(1, area.Width / dpi - 16));
            window.MaxHeight = Math.Min(460, Math.Max(1, area.Height / dpi - 16));
            window.SizeToContent = SizeToContent.Height;
        }
        else
        {
            window.SizeToContent = SizeToContent.Manual;
            window.MaxHeight = double.PositiveInfinity;
            window.Width = 36;
            window.Height = 84;
        }
        window.UpdateLayout();
        NativeWindow.Rect rect;
        if (!NativeWindow.GetWindowRect(hwnd, out rect)) return;
        int inset = expanded ? (int)Math.Round(8 * dpi) : 0;
        int x = Math.Max(area.Left, area.Right - (rect.Right - rect.Left) - inset);
        int y = area.Top + (int)Math.Round(Math.Max(0, (area.Height - (rect.Bottom - rect.Top)) * 0.40));
        if (x != rect.Left || y != rect.Top) NativeWindow.Move(hwnd, x, y);
    }

    private void SetExpanded(bool value, bool restoreFocus = true)
    {
        if (value == expanded) return;
        expanded = value;
        handle.Visibility = Visible(!value);
        shell.Visibility = Visible(value);
        if (value)
        {
            previous = NativeWindow.GetForegroundWindow();
            if (SystemParameters.ClientAreaAnimation)
                shell.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(150)));
            Place();
            window.Activate();
            settings.Focus();
            foreground = NativeWindow.GetForegroundWindow();
            scroll.ScrollToTop();
            send(new { type = "expand" });
        }
        else
        {
            bool ownsFocus = NativeWindow.GetForegroundWindow() == hwnd;
            Place();
            if (restoreFocus && ownsFocus && previous != hwnd && NativeWindow.IsWindow(previous))
                NativeWindow.SetForegroundWindow(previous);
            previous = foreground = IntPtr.Zero;
            send(new { type = "collapse" });
        }
    }

    private void UpdateForeground()
    {
        if (!expanded || hiddenId.HasValue || !window.IsVisible) return;
        var current = NativeWindow.GetForegroundWindow();
        if (current == IntPtr.Zero) return;
        if (current != hwnd && foreground != IntPtr.Zero && current != foreground)
            SetExpanded(false, restoreFocus: false);
        else
            foreground = current;
    }

    private void Render(HostMessage state)
    {
        monitor = state.Monitor ?? "";
        var snapshot = state.Snapshot ?? new PanelSnapshot();
        var panels = state.Panels ?? new PanelEntry[0];
        var panel = panels.FirstOrDefault(entry => entry.Key == state.Selected);
        if (scrollPanel != state.Selected || scrollSettings != state.Settings)
        {
            scroll.ScrollToTop();
            scrollPanel = state.Selected;
            scrollSettings = state.Settings;
        }
        tabs.Children.Clear();
        tabs.Visibility = Visibility.Collapsed;
        items.Children.Clear();
        preferences.Children.Clear();
        actions.Children.Clear();
        refresh.IsEnabled = panel != null && !state.Settings && snapshot.Status != "loading";
        string settingsLabel = state.Settings ? "返回面板" : "设置";
        settings.ToolTip = settingsLabel;
        AutomationProperties.SetName(settings, settingsLabel);
        preferences.Visibility = Visible(state.Settings);
        hero.Visibility = Visible(!state.Settings);
        notice.Visibility = Visible(!state.Settings && !string.IsNullOrEmpty(snapshot.Message));
        notice.Text = snapshot.Message ?? "";

        if (state.Settings)
            RenderSettings(panels, state.DefaultPanel);
        else
            RenderPanel(panel, panels.Where(entry => entry.Enabled).ToArray(), snapshot);
        Place();
    }

    private void RenderSettings(PanelEntry[] panels, string defaultPanel)
    {
        AddText(preferences, "面板设置", 25, "#F2F4EF", new Thickness(0, 0, 0, 10));
        foreach (var entry in panels)
        {
            bool isDefault = entry.Key == defaultPanel;
            AddText(preferences, entry.Title + (isDefault ? " · 默认" : ""), 14, "#F2F4EF", new Thickness(0, 8, 0, 5));
            var row = new WrapPanel();
            preferences.Children.Add(row);
            AddChoice(row, entry.Enabled ? "停用" : "启用", new { type = "toggle", key = entry.Key });
            if (entry.Enabled && !isDefault)
                AddChoice(row, "设为默认", new { type = "default", key = entry.Key });
        }
        AddText(preferences, "显示器", 16, "#F2F4EF", new Thickness(0, 14, 0, 8));
        AddChoice(preferences, "主显示器（自动）", new { type = "monitor", monitor = "" }, enabled: monitor != "");
        int number = 0;
        foreach (var screen in Screen.AllScreens)
        {
            bool selected = screen.DeviceName == monitor;
            var label = string.Format("显示器 {0} · {1} × {2}", ++number, screen.Bounds.Width, screen.Bounds.Height);
            AddChoice(preferences, label + (selected ? " · 已选" : ""),
                new { type = "monitor", monitor = screen.DeviceName }, enabled: !selected);
        }
    }

    private void RenderPanel(PanelEntry panel, PanelEntry[] choices, PanelSnapshot snapshot)
    {
        if (choices.Length > 1)
        {
            tabs.Visibility = Visibility.Visible;
            var navigation = new WrapPanel();
            tabs.Children.Add(navigation);
            foreach (var entry in choices)
                AddChoice(navigation, entry.Title, new { type = "select", key = entry.Key }, entry == panel ? "Primary" : "Choice");
        }
        title.Text = panel == null ? "暂无可用面板" : panel.Title;
        captureArt.Visibility = Visible(panel != null && panel.Key == "dsh-screenshot:desktop");
        if (panel == null) summary.Text = "请在设置中启用面板，或安装提供面板的插件。";
        else if (snapshot.Status == "loading") summary.Text = "正在读取…";
        else if (snapshot.Status == "error") summary.Text = "暂时无法读取面板。";
        else if (!string.IsNullOrEmpty(snapshot.Summary)) summary.Text = snapshot.Summary;
        else summary.Text = snapshot.Status == "empty" ? "暂无内容。" : "";

        foreach (var item in snapshot.Items ?? new PanelItem[0])
        {
            var row = new StackPanel { Background = Brush("#20251F"), Margin = new Thickness(0, 0, 0, 4) };
            AddText(row, item.Text, 14, "#F2F4EF", new Thickness(11, 8, 11, 6));
            if (!string.IsNullOrEmpty(item.Status))
                AddText(row, item.Status, 12, "#AEB4AA", new Thickness(11, 0, 11, 8));
            items.Children.Add(row);
        }
        if (panel == null)
        {
            AddChoice(actions, "打开设置", new { type = "settings" }, "Primary");
            return;
        }
        string style = "Primary";
        foreach (var action in snapshot.Actions ?? new PanelAction[0])
        {
            AddChoice(actions, action.Label, new { type = "action", id = action.Id, key = panel.Key, revision = snapshot.Revision },
                style, !action.Disabled);
            style = "Button";
        }
    }

    private void AddChoice(Panel parent, string label, object message, string style = "Choice", bool enabled = true)
    {
        var button = new Button
        {
            Style = (Style)window.FindResource(style),
            Content = new TextBlock { Text = label, TextWrapping = TextWrapping.Wrap },
            IsEnabled = enabled,
            Margin = parent == actions ? new Thickness(0, 0, 0, 4) : new Thickness(0, 0, 6, 6)
        };
        button.Click += (sender, e) => send(message);
        parent.Children.Add(button);
    }

    private static void AddText(Panel parent, string text, double size, string color, Thickness margin)
    {
        parent.Children.Add(new TextBlock
        {
            Text = text, FontSize = size, Foreground = Brush(color), Margin = margin, TextWrapping = TextWrapping.Wrap
        });
    }

    private static Brush Brush(string color)
    {
        return (Brush)new BrushConverter().ConvertFromString(color);
    }

    private static Visibility Visible(bool value)
    {
        return value ? Visibility.Visible : Visibility.Collapsed;
    }
}
