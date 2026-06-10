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

    public static DesktopBootstrap Bootstrap(WindowsHostConfig config, WindowsNativePreferencesStore? preferencesStore = null)
    {
        var preferences = (preferencesStore ?? new WindowsNativePreferencesStore()).Load();
        var localProxyAvailable = config.LocalProxyAvailable;
        var localModeEnabled = localProxyAvailable && preferences.OperatingMode == "local";
        var operatingMode = localModeEnabled ? "local" : "remote";
        var managementBridgeReady = localModeEnabled || !string.IsNullOrWhiteSpace(config.ManagementBaseUrl);

        return new DesktopBootstrap(
            UiEnabled: true,
            BasePath: "/",
            BridgeVersion: Quotio.Contract.QuotioContract.Version,
            ServerListen: config.ServerListen,
            Platform: "windows",
            OperatingMode: operatingMode,
            Locale: preferences.Language,
            Appearance: preferences.Appearance,
            Features: new Dictionary<string, bool>
            {
                ["overview"] = managementBridgeReady,
                ["providers"] = managementBridgeReady,
                ["quota"] = managementBridgeReady,
                ["usage"] = managementBridgeReady,
                ["virtualModels"] = managementBridgeReady,
                ["models"] = managementBridgeReady,
                ["agents"] = localModeEnabled,
                ["apiKeys"] = managementBridgeReady,
                ["logs"] = managementBridgeReady,
                ["settings"] = true,
                ["about"] = true
            },
            Capabilities: new Dictionary<string, bool>
            {
                ["supportsLocalProxy"] = localProxyAvailable,
                ["supportsProxyControl"] = localModeEnabled,
                ["supportsPortConfig"] = localModeEnabled,
                ["supportsCliOAuth"] = localModeEnabled,
                ["supportsAgentConfig"] = localModeEnabled,
                ["supportsRemoteConnections"] = true,
                ["supportsCredentialStorage"] = true,
                ["supportsManagementBridge"] = managementBridgeReady,
                ["supportsNativeOnboarding"] = false,
                ["supportsNativePreferences"] = true,
                ["supportsTrayBehavior"] = true,
                ["supportsAppearanceSync"] = true,
                ["supportsRequestLogSettings"] = true,
                ["supportsModelSettings"] = true,
                ["supportsApiKeyManagement"] = true,
                ["supportsVirtualModelManagement"] = true,
                ["supportsUpdates"] = true
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
