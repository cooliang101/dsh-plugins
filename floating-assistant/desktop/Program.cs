using System;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Markup;

internal static class Program
{
    [STAThread]
    private static int Main()
    {
        try
        {
            Console.SetError(new StreamWriter(Console.OpenStandardError(), new UTF8Encoding(false)) { AutoFlush = true });
            AppContext.SetSwitch("Switch.System.Windows.DoNotScaleForDpiChanges", false);
            var app = new Application();
            app.DispatcherUnhandledException += (sender, e) =>
            {
                Console.Error.WriteLine(e.Exception);
                e.Handled = true;
                app.Shutdown(1);
            };
            Window window;
            using (var xaml = Assembly.GetExecutingAssembly().GetManifestResourceStream("panel.xaml"))
                window = (Window)XamlReader.Load(xaml);

            using (var input = new StreamReader(Console.OpenStandardInput(), new UTF8Encoding(false)))
            using (var output = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false)) { AutoFlush = true })
            {
                var json = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
                var panel = new PanelWindow(window, message => output.WriteLine(json.Serialize(message)));
                RoutedEventHandler loaded = null;
                loaded = (sender, e) =>
                {
                    window.Loaded -= loaded;
                    panel.Ready();
                    Task.Run(() => ReadMessages(input, app, panel));
                };
                window.Loaded += loaded;
                return app.Run(window);
            }
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(error);
            return 1;
        }
    }

    private static void ReadMessages(TextReader input, Application app, PanelWindow panel)
    {
        var json = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
        try
        {
            string line;
            while ((line = input.ReadLine()) != null)
            {
                var message = json.Deserialize<HostMessage>(line);
                app.Dispatcher.Invoke(() => panel.Receive(message));
            }
            app.Dispatcher.BeginInvoke(new Action(() => app.Shutdown()));
        }
        catch (Exception error)
        {
            if (app.Dispatcher.HasShutdownStarted) return;
            Console.Error.WriteLine(error);
            app.Dispatcher.BeginInvoke(new Action(() => app.Shutdown(1)));
        }
    }
}

internal sealed class HostMessage
{
    public string Type { get; set; }
    public long Id { get; set; }
    public bool Settings { get; set; }
    public string Monitor { get; set; }
    public string Selected { get; set; }
    public string DefaultPanel { get; set; }
    public PanelEntry[] Panels { get; set; }
    public PanelSnapshot Snapshot { get; set; }
}

internal sealed class PanelEntry
{
    public string Key { get; set; }
    public string Title { get; set; }
    public bool Enabled { get; set; }
}

internal sealed class PanelSnapshot
{
    public long Revision { get; set; }
    public string Status { get; set; }
    public string Summary { get; set; }
    public string Message { get; set; }
    public PanelItem[] Items { get; set; }
    public PanelAction[] Actions { get; set; }
}

internal sealed class PanelItem
{
    public string Text { get; set; }
    public string Status { get; set; }
}

internal sealed class PanelAction
{
    public string Id { get; set; }
    public string Label { get; set; }
    public bool Disabled { get; set; }
}
