namespace Quotio.Windows;

public sealed class WindowsHostConfig
{
    private const string DefaultEndpoint = "http://127.0.0.1:8386";
    private const string DefaultAuthority = "127.0.0.1:8386";
    private readonly Func<string, string?> credentialReader;

    public WindowsHostConfig()
        : this(WindowsCredentialStore.TryReadGenericCredential)
    {
    }

    public WindowsHostConfig(Func<string, string?> credentialReader)
    {
        this.credentialReader = credentialReader;
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
}
