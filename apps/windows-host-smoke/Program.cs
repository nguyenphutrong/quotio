using System.Text.Json;
using Quotio.Windows;

var savedEnvironment = new Dictionary<string, string?>
{
    ["QUOTIO_DESKTOP_UI_DEV_SERVER"] = Environment.GetEnvironmentVariable("QUOTIO_DESKTOP_UI_DEV_SERVER"),
    ["QUOTIO_MANAGEMENT_BASE_URL"] = Environment.GetEnvironmentVariable("QUOTIO_MANAGEMENT_BASE_URL"),
    ["QUOTIO_MANAGEMENT_KEY"] = Environment.GetEnvironmentVariable("QUOTIO_MANAGEMENT_KEY"),
    ["QUOTIO_PROXY_ENDPOINT"] = Environment.GetEnvironmentVariable("QUOTIO_PROXY_ENDPOINT")
};

try
{
    RunConfigSmoke();
    RunBootstrapSmoke();
    RunAgentAdapterSmoke();
}
finally
{
    foreach (var (key, value) in savedEnvironment)
    {
        Environment.SetEnvironmentVariable(key, value);
    }
}

Console.WriteLine("Windows host smoke checks passed");

static void RunConfigSmoke()
{
    ClearEnvironment();
    var fallbackConfig = new WindowsHostConfig(target => target switch
    {
        "Quotio/DesktopUiDevServer" => " https://credential-ui.example ",
        "Quotio/ManagementBaseUrl" => " http://credential-management.example ",
        "Quotio/ManagementKey" => " credential-management-key ",
        "Quotio/ProxyEndpoint" => " http://127.0.0.1:9393 ",
        _ => null
    });

    Assert(fallbackConfig.DesktopUiDevServer == "https://credential-ui.example", "Credential fallback should trim dev server");
    Assert(fallbackConfig.ManagementBaseUrl == "http://credential-management.example", "Credential fallback should trim management base URL");
    Assert(fallbackConfig.ManagementKey == "credential-management-key", "Credential fallback should trim management key");
    Assert(fallbackConfig.ProxyEndpoint == "http://127.0.0.1:9393", "Credential fallback should provide proxy endpoint");
    Assert(fallbackConfig.ServerListen == "127.0.0.1:9393", "ServerListen should derive from proxy endpoint authority");

    Environment.SetEnvironmentVariable("QUOTIO_DESKTOP_UI_DEV_SERVER", " http://localhost:5173 ");
    Environment.SetEnvironmentVariable("QUOTIO_MANAGEMENT_BASE_URL", " http://localhost:8386 ");
    Environment.SetEnvironmentVariable("QUOTIO_MANAGEMENT_KEY", " env-management-key ");
    Environment.SetEnvironmentVariable("QUOTIO_PROXY_ENDPOINT", " http://127.0.0.1:8484 ");

    var envConfig = new WindowsHostConfig(_ => "credential-value");
    Assert(envConfig.DesktopUiDevServer == "http://localhost:5173", "Environment dev server should win over credentials");
    Assert(envConfig.ManagementBaseUrl == "http://localhost:8386", "Environment base URL should win over credentials");
    Assert(envConfig.ManagementKey == "env-management-key", "Environment management key should win over credentials");
    Assert(envConfig.ProxyEndpoint == "http://127.0.0.1:8484", "Environment proxy endpoint should win over credentials");
    Assert(envConfig.ServerListen == "127.0.0.1:8484", "ServerListen should use environment proxy endpoint");
}

static void RunBootstrapSmoke()
{
    Environment.SetEnvironmentVariable("QUOTIO_PROXY_ENDPOINT", "http://127.0.0.1:8585");
    var bootstrap = DesktopUiSource.Bootstrap(new WindowsHostConfig(_ => null));

    Assert(bootstrap.UiEnabled, "Windows bootstrap should enable shared UI");
    Assert(bootstrap.Platform == "windows", "Windows bootstrap should identify the platform");
    Assert(bootstrap.ServerListen == "127.0.0.1:8585", "Windows bootstrap should expose server listen authority");
    Assert(bootstrap.Features["agents"], "Windows bootstrap should expose read-only agents");
    Assert(bootstrap.Features["settings"], "Windows bootstrap should expose shared settings placeholder");
    Assert(bootstrap.Features["about"], "Windows bootstrap should expose shared about placeholder");
    Assert(!bootstrap.Capabilities["supportsAgentConfig"], "Windows bootstrap should not claim agent write support");
    Assert(!bootstrap.Capabilities["supportsCredentialStorage"], "Windows bootstrap should not claim credential editing support");
}

static void RunAgentAdapterSmoke()
{
    var adapter = new WindowsAgentAdapter();
    using var list = ToJsonDocument(adapter.Handle("/agents", "GET"));
    var agents = list.RootElement.GetProperty("agents");
    Assert(agents.GetArrayLength() >= 5, "Windows agents endpoint should return descriptors");

    var codex = agents.EnumerateArray().First(agent => agent.GetProperty("id").GetString() == "codex");
    Assert(codex.GetProperty("capabilities").EnumerateArray().Select(value => value.GetString()).SequenceEqual(["guide"]), "Windows descriptors should be guide-only");
    Assert(!codex.GetProperty("rollback_available").GetBoolean(), "Windows descriptors should not claim rollback");

    using var guide = ToJsonDocument(adapter.Handle("/agents/codex/guide", "GET"));
    Assert(guide.RootElement.GetProperty("guide").GetProperty("tool").GetString() == "codex", "Guide endpoint should return the requested agent");

    using var diff = ToJsonDocument(adapter.Handle("/agents/codex/diff", "POST"));
    Assert(diff.RootElement.GetProperty("plan").GetProperty("files").GetArrayLength() == 0, "Diff preview should be read-only");

    using var install = ToJsonDocument(adapter.Handle("/agents/codex/install", "POST"));
    Assert(install.RootElement.GetProperty("summary").GetString()?.Contains("disabled", StringComparison.OrdinalIgnoreCase) == true, "Install should stay disabled");
    Assert(!install.RootElement.GetProperty("status").GetProperty("rollback_available").GetBoolean(), "Install response should not claim rollback");

    using var rollback = ToJsonDocument(adapter.Handle("/agents/codex/rollback", "POST"));
    Assert(rollback.RootElement.GetProperty("summary").GetString()?.Contains("disabled", StringComparison.OrdinalIgnoreCase) == true, "Rollback should stay disabled");
}

static JsonDocument ToJsonDocument(object value)
{
    return JsonDocument.Parse(JsonSerializer.Serialize(value));
}

static void ClearEnvironment()
{
    Environment.SetEnvironmentVariable("QUOTIO_DESKTOP_UI_DEV_SERVER", null);
    Environment.SetEnvironmentVariable("QUOTIO_MANAGEMENT_BASE_URL", null);
    Environment.SetEnvironmentVariable("QUOTIO_MANAGEMENT_KEY", null);
    Environment.SetEnvironmentVariable("QUOTIO_PROXY_ENDPOINT", null);
}

static void Assert(bool condition, string message)
{
    if (!condition)
    {
        throw new InvalidOperationException(message);
    }
}
