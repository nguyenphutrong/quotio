namespace Quotio.Windows;

using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using global::Windows.Graphics;
using WinRT.Interop;
using Forms = System.Windows.Forms;

public sealed partial class MainWindow : Window
{
    private readonly WindowsHostConfig config = new();
    private readonly WindowsAgentAdapter agents;
    private readonly WindowSettingsStore settingsStore = new();
    private readonly RuntimeProcessController runtime;
    private readonly DesktopBridge bridge;
    private readonly Forms.NotifyIcon trayIcon;
    private AppWindow? appWindow;

    public MainWindow()
    {
        InitializeComponent();

        agents = new WindowsAgentAdapter(config);
        runtime = new RuntimeProcessController(config);
        bridge = new DesktopBridge(DesktopWebView, runtime, config, agents);
        trayIcon = CreateTrayIcon();

        Title = "Quotio";
        SystemBackdrop = new MicaBackdrop();

        ConfigureWindow();
        _ = InitializeWebViewAsync();

        Closed += OnClosed;
    }

    public void ShowFromActivation()
    {
        Activate();
        if (appWindow?.Presenter is OverlappedPresenter presenter)
        {
            presenter.Restore();
        }
    }

    private void ConfigureWindow()
    {
        var hwnd = WindowNative.GetWindowHandle(this);
        var windowId = Win32Interop.GetWindowIdFromWindow(hwnd);
        appWindow = AppWindow.GetFromWindowId(windowId);

        appWindow.Title = "Quotio";

        if (settingsStore.TryLoad(out var placement))
        {
            appWindow.MoveAndResize(ToRect(WindowPlacementService.RestoreBounds(
                placement,
                GetDisplayWorkAreas()
            )));
        }
        else
        {
            appWindow.Resize(new SizeInt32(1100, 700));
        }
    }

    private async Task InitializeWebViewAsync()
    {
        try
        {
            await DesktopWebView.EnsureCoreWebView2Async();

            var core = DesktopWebView.CoreWebView2;
            core.Settings.AreDefaultContextMenusEnabled = false;
            core.Settings.AreDevToolsEnabled = IsDebugHost();
            core.WebMessageReceived += bridge.OnWebMessageReceived;

            await core.AddScriptToExecuteOnDocumentCreatedAsync(
                bridge.CreateBootstrapScript(DesktopUiSource.Bootstrap(config))
            );

            var source = DesktopUiSource.Resolve(config);
            if (source is null)
            {
                ShowError("Run the desktop UI build or set QUOTIO_DESKTOP_UI_DEV_SERVER.");
                return;
            }

            DesktopWebView.Source = source;
        }
        catch (Exception error)
        {
            DiagnosticLog.Error("WebView initialization failed", error);
            ShowError(error.Message);
        }
    }

    private void ShowError(string message)
    {
        ErrorText.Text = message;
        ErrorPanel.Visibility = Visibility.Visible;
    }

    private Forms.NotifyIcon CreateTrayIcon()
    {
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("Open Quotio", null, (_, _) => DispatcherQueue.TryEnqueue(ShowFromActivation));
        menu.Items.Add("Quit", null, (_, _) => DispatcherQueue.TryEnqueue(Close));

        var icon = new Forms.NotifyIcon
        {
            Text = "Quotio",
            Icon = System.Drawing.SystemIcons.Application,
            ContextMenuStrip = menu,
            Visible = true
        };
        icon.DoubleClick += (_, _) => DispatcherQueue.TryEnqueue(ShowFromActivation);
        return icon;
    }

    private void OnClosed(object sender, WindowEventArgs args)
    {
        if (appWindow is not null)
        {
            settingsStore.Save(
                appWindow.Position,
                appWindow.Size,
                ResolveMonitorDeviceName(appWindow.Position, appWindow.Size)
            );
        }

        trayIcon.Visible = false;
        trayIcon.Dispose();
        runtime.Dispose();
        DesktopWebView.CoreWebView2?.Stop();
    }

    private static bool IsDebugHost()
    {
#if DEBUG
        return true;
#else
        return false;
#endif
    }

    private static RectInt32 ToRect(WindowBounds bounds)
    {
        return new RectInt32(bounds.X, bounds.Y, bounds.Width, bounds.Height);
    }

    private static IReadOnlyList<DisplayWorkArea> GetDisplayWorkAreas()
    {
        return Forms.Screen.AllScreens.Select(screen => new DisplayWorkArea(
            screen.DeviceName,
            screen.WorkingArea.Left,
            screen.WorkingArea.Top,
            screen.WorkingArea.Right,
            screen.WorkingArea.Bottom
        )).ToArray();
    }

    private static string? ResolveMonitorDeviceName(PointInt32 position, SizeInt32 size)
    {
        return Forms.Screen.FromRectangle(ToDrawingRectangle(
            position.X,
            position.Y,
            Math.Max(size.Width, 1),
            Math.Max(size.Height, 1)
        )).DeviceName;
    }

    private static System.Drawing.Rectangle ToDrawingRectangle(
        int x,
        int y,
        int width,
        int height
    )
    {
        return new System.Drawing.Rectangle(x, y, width, height);
    }

}
