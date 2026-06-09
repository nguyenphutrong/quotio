namespace Quotio.Windows;

public static class DesktopUiSource
{
    public static Uri? Resolve()
    {
        var devServer = Environment.GetEnvironmentVariable("QUOTIO_DESKTOP_UI_DEV_SERVER")?.Trim();
        if (!string.IsNullOrEmpty(devServer) && Uri.TryCreate(devServer, UriKind.Absolute, out var devUri))
        {
            return devUri;
        }

        var bundledIndex = Path.Combine(AppContext.BaseDirectory, "desktop-ui", "index.html");
        if (File.Exists(bundledIndex))
        {
            return new Uri(bundledIndex);
        }

        return null;
    }

    public static DesktopBootstrap Bootstrap()
    {
        return new DesktopBootstrap(
            UiEnabled: true,
            BasePath: "/",
            BridgeVersion: Quotio.Contract.QuotioContract.Version,
            ServerListen: "localhost:8386",
            Platform: "windows",
            Locale: Thread.CurrentThread.CurrentUICulture.Name,
            Appearance: "system"
        );
    }
}

public sealed record DesktopBootstrap(
    bool UiEnabled,
    string BasePath,
    int BridgeVersion,
    string ServerListen,
    string Platform,
    string Locale,
    string Appearance
);
