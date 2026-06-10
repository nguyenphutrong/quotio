namespace Quotio.Windows;

public static class DesktopUiSource
{
    public static Uri? Resolve(WindowsHostConfig config)
    {
        var devServer = config.DesktopUiDevServer;
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

    public static DesktopBootstrap Bootstrap(WindowsHostConfig config)
    {
        return new DesktopBootstrap(
            UiEnabled: true,
            BasePath: "/",
            BridgeVersion: Quotio.Contract.QuotioContract.Version,
            ServerListen: config.ServerListen,
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
                ["virtualModels"] = true,
                ["models"] = true,
                ["agents"] = true,
                ["apiKeys"] = true,
                ["logs"] = true,
                ["settings"] = true,
                ["about"] = true
            },
            Capabilities: new Dictionary<string, bool>
            {
                ["supportsLocalProxy"] = true,
                ["supportsProxyControl"] = true,
                ["supportsPortConfig"] = true,
                ["supportsCliOAuth"] = true,
                ["supportsAgentConfig"] = false,
                ["supportsRemoteConnections"] = true,
                ["supportsCredentialStorage"] = true,
                ["supportsNativeOnboarding"] = false,
                ["supportsNativePreferences"] = false,
                ["supportsAppearanceSync"] = true,
                ["supportsRequestLogSettings"] = false,
                ["supportsModelSettings"] = false,
                ["supportsApiKeyManagement"] = false,
                ["supportsVirtualModelManagement"] = false
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
