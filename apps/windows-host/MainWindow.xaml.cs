namespace Quotio.Windows;

using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using global::Windows.Graphics;
using System.Runtime.InteropServices;
using WinRT.Interop;
using Forms = System.Windows.Forms;

public sealed partial class MainWindow : Window
{
    private readonly WindowsHostConfig config = new();
    private readonly WindowsAgentAdapter agents;
    private readonly WindowSettingsStore settingsStore = new();
    private readonly WindowsNativePreferencesStore preferencesStore = new();
    private readonly RuntimeProcessController runtime;
    private readonly WindowsUpdateService updates;
    private readonly DesktopBridge bridge;
    private readonly Forms.NotifyIcon trayIcon;
    private AppWindow? appWindow;
    private nint hwnd;
    private bool isQuitting;

    public MainWindow()
    {
        InitializeComponent();
        ConfigureWebViewStartupBackground();

        agents = new WindowsAgentAdapter(config);
        runtime = new RuntimeProcessController(config);
        updates = new WindowsUpdateService(config, preferencesStore);
        trayIcon = CreateTrayIcon();
        bridge = new DesktopBridge(
            DesktopWebView,
            runtime,
            config,
            agents,
            preferencesStore,
            updates,
            ShowNativeNotification
        );

        Title = "Quotio";
        SystemBackdrop = new MicaBackdrop();

        ConfigureWindow();
        _ = InitializeWebViewAsync();

        Closed += OnClosed;
    }

    public void ShowFromActivation()
    {
        if (hwnd != 0)
        {
            ShowWindow(hwnd, ShowWindowCommand.Show);
        }

        Activate();
        if (appWindow?.Presenter is OverlappedPresenter presenter)
        {
            presenter.Restore();
        }
    }

    private void ConfigureWindow()
    {
        hwnd = WindowNative.GetWindowHandle(this);
        var windowId = Win32Interop.GetWindowIdFromWindow(hwnd);
        appWindow = AppWindow.GetFromWindowId(windowId);

        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBarDragRegion);
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
            DesktopWebView.DefaultBackgroundColor = Colors.Transparent;

            var core = DesktopWebView.CoreWebView2;
            core.Settings.AreDefaultContextMenusEnabled = true;
            core.Settings.AreDevToolsEnabled = IsDebugHost();
            core.WebMessageReceived += bridge.OnWebMessageReceived;

            await core.AddScriptToExecuteOnDocumentCreatedAsync(
                bridge.CreateBootstrapScript(DesktopUiSource.Bootstrap(config, preferencesStore))
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

    private void OnBackClicked(object sender, RoutedEventArgs args)
    {
        if (DesktopWebView.CoreWebView2?.CanGoBack == true)
        {
            DesktopWebView.CoreWebView2.GoBack();
        }
    }

    private void OnRefreshClicked(object sender, RoutedEventArgs args)
    {
        DesktopWebView.CoreWebView2?.Reload();
    }

    private async void OnSettingsClicked(object sender, RoutedEventArgs args)
    {
        if (DesktopWebView.CoreWebView2 is null)
        {
            return;
        }

        await DesktopWebView.CoreWebView2.ExecuteScriptAsync(
            """
            (() => {
              history.pushState({}, '', '/settings');
              window.dispatchEvent(new PopStateEvent('popstate'));
            })();
            """
        );
    }

    private bool ShowNativeNotification(string title, string message, string tone)
    {
        if (!preferencesStore.Load().NotificationsEnabled)
        {
            return false;
        }

        var icon = tone == "error"
            ? Forms.ToolTipIcon.Error
            : Forms.ToolTipIcon.Info;
        trayIcon.ShowBalloonTip(3000, title, message, icon);
        return true;
    }

    private Forms.NotifyIcon CreateTrayIcon()
    {
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("Open Quotio", null, (_, _) => DispatcherQueue.TryEnqueue(ShowFromActivation));
        menu.Items.Add("Quit", null, (_, _) => DispatcherQueue.TryEnqueue(Quit));

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
        SaveWindowPlacement();

        if (!isQuitting)
        {
            args.Handled = true;
            HideToTray();
            return;
        }

        trayIcon.Visible = false;
        trayIcon.Dispose();
        runtime.Dispose();
        DesktopWebView.CoreWebView2?.Stop();
    }

    private void Quit()
    {
        isQuitting = true;
        Close();
    }

    private void HideToTray()
    {
        if (hwnd != 0)
        {
            ShowWindow(hwnd, ShowWindowCommand.Hide);
        }
    }

    private void SaveWindowPlacement()
    {
        if (appWindow is not null)
        {
            settingsStore.Save(
                appWindow.Position,
                appWindow.Size,
                ResolveMonitorDeviceName(appWindow.Position, appWindow.Size)
            );
        }
    }

    private static bool IsDebugHost()
    {
#if DEBUG
        return true;
#else
        return false;
#endif
    }

    private static void ConfigureWebViewStartupBackground()
    {
        Environment.SetEnvironmentVariable(
            "WEBVIEW2_DEFAULT_BACKGROUND_COLOR",
            "0x00000000"
        );
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

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(nint hWnd, ShowWindowCommand command);

    private enum ShowWindowCommand
    {
        Hide = 0,
        Show = 5
    }
}
