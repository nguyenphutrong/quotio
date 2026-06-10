namespace Quotio.Windows;

public sealed class WindowsHostConfig
{
    private const string DefaultEndpoint = "http://127.0.0.1:8386";
    private const string DefaultAuthority = "127.0.0.1:8386";
    private const string DefaultWindowsUpdateRepositoryUrl = "https://github.com/nguyenphutrong/quotio";
    private const string BundledWindowsUpdateChannelFile = "windows-update-channel.txt";
    private readonly Func<string, string?> credentialReader;
    private readonly string appBaseDirectory;

    public WindowsHostConfig()
        : this(WindowsCredentialStore.TryReadGenericCredential)
    {
    }

    public WindowsHostConfig(Func<string, string?> credentialReader, string? appBaseDirectory = null)
    {
        this.credentialReader = credentialReader;
        this.appBaseDirectory = appBaseDirectory ?? AppContext.BaseDirectory;
    }

    public string? DesktopUiDevServer => ReadValue(
        "QUOTIO_DESKTOP_UI_DEV_SERVER",
        "Quotio/DesktopUiDevServer"
    );

    public string? ManagementBaseUrl => ReadValue(
        "QUOTIO_MANAGEMENT_BASE_URL",
        "Quotio/ManagementBaseUrl"
    );

    public string? ManagementKey => ReadValue(
        "QUOTIO_MANAGEMENT_KEY",
        "Quotio/ManagementKey"
    );

    public string? ProxyBinary => ReadValue(
        "QUOTIO_PROXY_BINARY",
        "Quotio/ProxyBinary"
    );

    public bool LocalProxyAvailable => !string.IsNullOrWhiteSpace(ProxyBinary)
        && File.Exists(ProxyBinary);

    public string? ProxyArgs => ReadValue(
        "QUOTIO_PROXY_ARGS",
        "Quotio/ProxyArgs"
    );

    public string ProxyEndpoint => ReadValue(
        "QUOTIO_PROXY_ENDPOINT",
        "Quotio/ProxyEndpoint"
    ) ?? DefaultEndpoint;

    public string ServerListen => Uri.TryCreate(ProxyEndpoint, UriKind.Absolute, out var endpoint)
        ? endpoint.Authority
        : DefaultAuthority;

    public string? WindowsUpdateRepositoryUrl => ReadValue(
        "QUOTIO_WINDOWS_UPDATE_REPOSITORY_URL",
        "Quotio/WindowsUpdateRepositoryUrl"
    ) ?? DefaultWindowsUpdateRepositoryUrl;

    public string WindowsUpdateChannel => NormalizeUpdateChannel(
        ReadValue(
            "QUOTIO_WINDOWS_UPDATE_CHANNEL",
            "Quotio/WindowsUpdateChannel"
        ) ?? ReadBundledWindowsUpdateChannel()
    );

    public bool WindowsUpdateChannelLocked => !string.IsNullOrWhiteSpace(
        ReadBundledWindowsUpdateChannel()
    );

    private static string NormalizeUpdateChannel(string? channel)
    {
        return channel?.Trim().ToLowerInvariant() == "beta" ? "beta" : "stable";
    }

    private string? ReadValue(string environmentVariable, string credentialTargetName)
    {
        var environmentValue = Environment.GetEnvironmentVariable(environmentVariable)?.Trim();
        if (!string.IsNullOrEmpty(environmentValue))
        {
            return environmentValue;
        }

        var credentialValue = credentialReader(credentialTargetName)?.Trim();
        return string.IsNullOrEmpty(credentialValue) ? null : credentialValue;
    }

    private string? ReadBundledWindowsUpdateChannel()
    {
        var path = Path.Combine(appBaseDirectory, BundledWindowsUpdateChannelFile);
        if (!File.Exists(path))
        {
            return null;
        }

        var channel = File.ReadAllText(path).Trim();
        return string.IsNullOrEmpty(channel) ? null : channel;
    }
}
