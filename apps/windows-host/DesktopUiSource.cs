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
            OperatingMode: "local",
            Locale: Thread.CurrentThread.CurrentUICulture.Name,
            Appearance: "system",
            Features: new Dictionary<string, bool>
            {
                ["overview"] = true,
                ["providers"] = true,
                ["quota"] = true,
                ["usage"] = true,
                ["virtualModels"] = false,
                ["models"] = false,
                ["agents"] = false,
                ["apiKeys"] = false,
                ["logs"] = false,
                ["settings"] = false,
                ["about"] = false
            },
            Capabilities: new Dictionary<string, bool>
            {
                ["supportsLocalProxy"] = true,
                ["supportsProxyControl"] = true,
                ["supportsPortConfig"] = true,
                ["supportsCliOAuth"] = true,
                ["supportsAgentConfig"] = false,
                ["supportsRemoteConnections"] = false,
                ["supportsCredentialStorage"] = false,
                ["supportsNativeOnboarding"] = false,
                ["supportsAppearanceSync"] = true
            }
        );
    }
}

public sealed record DesktopBootstrap(
    bool UiEnabled,
    string BasePath,
    int BridgeVersion,
    string ServerListen,
    string Platform,
    string OperatingMode,
    string Locale,
    string Appearance,
    IReadOnlyDictionary<string, bool> Features,
    IReadOnlyDictionary<string, bool> Capabilities
);
