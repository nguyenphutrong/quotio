namespace Quotio.Windows;

using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;
using WinRT.Interop;
using Forms = System.Windows.Forms;

public sealed partial class MainWindow : Window
{
    private readonly WindowSettingsStore settingsStore = new();
    private readonly DesktopBridge bridge;
    private readonly Forms.NotifyIcon trayIcon;
    private AppWindow? appWindow;

    public MainWindow()
    {
        InitializeComponent();

        bridge = new DesktopBridge(DesktopWebView);
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
            appWindow.MoveAndResize(new RectInt32(
                placement.X,
                placement.Y,
                Math.Max(placement.Width, 900),
                Math.Max(placement.Height, 600)
            ));
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
                bridge.CreateBootstrapScript(DesktopUiSource.Bootstrap())
            );

            var source = DesktopUiSource.Resolve();
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
            Icon = Forms.SystemIcons.Application,
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
            settingsStore.Save(appWindow.Position, appWindow.Size);
        }

        trayIcon.Visible = false;
        trayIcon.Dispose();
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
}
