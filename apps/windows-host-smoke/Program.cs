using System.Text.Json;
using System.Net;
using System.Net.Sockets;
using Quotio.Windows;

if (args.Contains("--runtime-child", StringComparer.Ordinal))
{
    Thread.Sleep(TimeSpan.FromSeconds(2));
    return;
}

var runtimeServerIndex = Array.IndexOf(args, "--runtime-child-server");
if (runtimeServerIndex >= 0)
{
    var host = args.ElementAtOrDefault(runtimeServerIndex + 1) ?? "127.0.0.1";
    var port = int.Parse(args.ElementAtOrDefault(runtimeServerIndex + 2) ?? "8686");
    var lifetimeSeconds = int.Parse(args.ElementAtOrDefault(runtimeServerIndex + 3) ?? "5");
    RunRuntimeChildServer(host, port, lifetimeSeconds);
    return;
}

var savedEnvironment = new Dictionary<string, string?>
{
    ["QUOTIO_DESKTOP_UI_DEV_SERVER"] = Environment.GetEnvironmentVariable("QUOTIO_DESKTOP_UI_DEV_SERVER"),
    ["QUOTIO_MANAGEMENT_BASE_URL"] = Environment.GetEnvironmentVariable("QUOTIO_MANAGEMENT_BASE_URL"),
    ["QUOTIO_MANAGEMENT_KEY"] = Environment.GetEnvironmentVariable("QUOTIO_MANAGEMENT_KEY"),
    ["QUOTIO_PROXY_ENDPOINT"] = Environment.GetEnvironmentVariable("QUOTIO_PROXY_ENDPOINT"),
    ["QUOTIO_PROXY_BINARY"] = Environment.GetEnvironmentVariable("QUOTIO_PROXY_BINARY"),
    ["QUOTIO_PROXY_ARGS"] = Environment.GetEnvironmentVariable("QUOTIO_PROXY_ARGS"),
    ["USERPROFILE"] = Environment.GetEnvironmentVariable("USERPROFILE"),
    ["LOCALAPPDATA"] = Environment.GetEnvironmentVariable("LOCALAPPDATA")
};

try
{
    RunConfigSmoke();
    RunBootstrapSmoke();
    RunWindowPlacementSmoke();
    RunRuntimeControllerSmoke();
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
    Assert(bootstrap.Features["virtualModels"], "Windows bootstrap should expose virtual models read-only");
    Assert(bootstrap.Features["agents"], "Windows bootstrap should expose read-only agents");
    Assert(bootstrap.Features["models"], "Windows bootstrap should expose shared model catalog");
    Assert(bootstrap.Features["apiKeys"], "Windows bootstrap should expose API key list");
    Assert(bootstrap.Features["logs"], "Windows bootstrap should expose request logs");
    Assert(bootstrap.Features["settings"], "Windows bootstrap should expose shared settings placeholder");
    Assert(bootstrap.Features["about"], "Windows bootstrap should expose shared about placeholder");
    Assert(!bootstrap.Capabilities["supportsAgentConfig"], "Windows bootstrap should not claim agent write support");
    Assert(!bootstrap.Capabilities["supportsCredentialStorage"], "Windows bootstrap should not claim credential editing support");
    Assert(!bootstrap.Capabilities["supportsRequestLogSettings"], "Windows bootstrap should keep request log settings read-only");
    Assert(!bootstrap.Capabilities["supportsModelSettings"], "Windows bootstrap should keep model settings read-only");
    Assert(!bootstrap.Capabilities["supportsApiKeyManagement"], "Windows bootstrap should keep API key management read-only");
    Assert(!bootstrap.Capabilities["supportsVirtualModelManagement"], "Windows bootstrap should keep virtual model management read-only");
}

static void RunWindowPlacementSmoke()
{
    DisplayWorkArea[] displays =
    [
        new("DISPLAY1", 0, 0, 1920, 1040),
        new("DISPLAY2", 1920, 0, 3840, 1040)
    ];

    var savedMonitor = WindowPlacementService.RestoreBounds(
        new WindowPlacement(3700, 900, 500, 400, "DISPLAY2"),
        displays
    );
    Assert(savedMonitor.Width == 900, "Window restore should enforce minimum width");
    Assert(savedMonitor.Height == 600, "Window restore should enforce minimum height");
    Assert(savedMonitor.X == 2940, "Window restore should clamp to saved monitor right edge");
    Assert(savedMonitor.Y == 440, "Window restore should clamp to saved monitor bottom edge");

    var missingMonitor = WindowPlacementService.RestoreBounds(
        new WindowPlacement(2100, 100, 1000, 700, "REMOVED"),
        displays
    );
    Assert(missingMonitor.X == 2100, "Window restore should use containing monitor when saved monitor is gone");

    var noDisplays = WindowPlacementService.RestoreBounds(
        new WindowPlacement(-300, -200, 1000, 700, null),
        []
    );
    Assert(noDisplays.X == -300 && noDisplays.Y == -200, "Window restore should preserve placement when display data is unavailable");
}

static void RunRuntimeControllerSmoke()
{
    ClearEnvironment();
    Environment.SetEnvironmentVariable("QUOTIO_PROXY_BINARY", Environment.ProcessPath);
    Environment.SetEnvironmentVariable("QUOTIO_PROXY_ENDPOINT", "http://127.0.0.1:8686");
    Environment.SetEnvironmentVariable("QUOTIO_PROXY_ARGS", "--runtime-child-server 127.0.0.1 8686");

    using var runtime = new RuntimeProcessController(new WindowsHostConfig(_ => null));
    var stopped = runtime.Status();
    Assert(stopped.State == "stopped", "Runtime should start stopped");
    Assert(stopped.Endpoint is null, "Stopped runtime should not expose an endpoint");

    var started = runtime.Start();
    Assert(started.State == "managed", "Runtime start should return managed status");
    Assert(started.Endpoint == "http://127.0.0.1:8686", "Runtime start should expose configured endpoint");

    var restarted = runtime.Restart();
    Assert(restarted.State == "managed", "Runtime restart should return managed status");
    Assert(restarted.Endpoint == "http://127.0.0.1:8686", "Runtime restart should preserve configured endpoint");

    var stoppedAgain = runtime.Stop();
    Assert(stoppedAgain.State == "stopped", "Runtime stop should return stopped status");
    Assert(stoppedAgain.Endpoint is null, "Runtime stop should clear endpoint");

    Environment.SetEnvironmentVariable("QUOTIO_PROXY_ENDPOINT", "http://127.0.0.1:8699");
    Environment.SetEnvironmentVariable("QUOTIO_PROXY_ARGS", "--runtime-child");
    using var unhealthyRuntime = new RuntimeProcessController(new WindowsHostConfig(_ => null));
    try
    {
        unhealthyRuntime.Start();
        throw new InvalidOperationException("Runtime start should reject an unreachable endpoint");
    }
    catch (InvalidOperationException error) when (error.Message.Contains("did not become reachable", StringComparison.OrdinalIgnoreCase))
    {
        var afterFailure = unhealthyRuntime.Status();
        Assert(afterFailure.State == "stopped", "Runtime start failure should clean up the child process");
        Assert(afterFailure.Endpoint is null, "Failed runtime should not expose an endpoint");
    }

    Environment.SetEnvironmentVariable("QUOTIO_PROXY_ENDPOINT", "http://127.0.0.1:8687");
    Environment.SetEnvironmentVariable("QUOTIO_PROXY_ARGS", "--runtime-child-server 127.0.0.1 8687 1");
    using var crashRuntime = new RuntimeProcessController(new WindowsHostConfig(_ => null));
    var crashStarted = crashRuntime.Start();
    Assert(crashStarted.State == "managed", "Short-lived runtime should start as managed");
    Thread.Sleep(TimeSpan.FromMilliseconds(1500));
    var crashed = crashRuntime.Status();
    Assert(crashed.State == "crashed", "Unexpected runtime exit should be reported as crashed");
    Assert(crashed.Endpoint is null, "Crashed runtime should not expose an endpoint");
    var afterCrash = crashRuntime.Status();
    Assert(afterCrash.State == "stopped", "Crash status should be reported once before stopped");
}

static void RunAgentAdapterSmoke()
{
    ClearEnvironment();
    Environment.SetEnvironmentVariable("QUOTIO_PROXY_ENDPOINT", "http://127.0.0.1:8787");
    Environment.SetEnvironmentVariable("QUOTIO_MANAGEMENT_KEY", "smoke-management-key");

    var smokeRoot = Path.Combine(Path.GetTempPath(), $"quotio-windows-agents-{Guid.NewGuid():N}");
    var home = Path.Combine(smokeRoot, "home");
    var localAppData = Path.Combine(smokeRoot, "local-app-data");
    Directory.CreateDirectory(Path.Combine(home, ".codex"));
    Directory.CreateDirectory(localAppData);
    Environment.SetEnvironmentVariable("USERPROFILE", home);
    Environment.SetEnvironmentVariable("LOCALAPPDATA", localAppData);

    var configPath = Path.Combine(home, ".codex", "config.toml");
    const string originalCodexConfig = "model = \"gpt-4.1\"\nmodel_provider = \"openai\"\n\n[model_providers.openai]\nname = \"OpenAI\"\n";
    File.WriteAllText(configPath, originalCodexConfig);

    var adapter = new WindowsAgentAdapter(
        new WindowsHostConfig(_ => null),
        new WindowsCodexConfigPatcher(home, Path.Combine(localAppData, "Quotio", "Codex"))
    );
    using var list = ToJsonDocument(adapter.Handle("/agents", "GET"));
    var agents = list.RootElement.GetProperty("agents");
    Assert(agents.GetArrayLength() >= 6, "Windows agents endpoint should return descriptors");

    var codex = agents.EnumerateArray().First(agent => agent.GetProperty("id").GetString() == "codex");
    Assert(codex.GetProperty("platform_support").GetString() == "supported", "Codex descriptor should expose read-only Windows support");
    Assert(codex.GetProperty("capabilities").EnumerateArray().Select(value => value.GetString()).SequenceEqual(["guide", "diff", "install"]), "Codex descriptor should expose install after Windows backup validation");
    Assert(!codex.GetProperty("rollback_available").GetBoolean(), "Codex should not claim rollback before a backup exists");

    var gemini = agents.EnumerateArray().First(agent => agent.GetProperty("id").GetString() == "gemini-cli");
    Assert(gemini.GetProperty("platform_support").GetString() == "guide-only", "Gemini descriptor should remain guide-only");
    Assert(gemini.GetProperty("capabilities").EnumerateArray().Select(value => value.GetString()).SequenceEqual(["guide"]), "Gemini descriptor should not expose diff until PowerShell writes are validated");

    var amp = agents.EnumerateArray().First(agent => agent.GetProperty("id").GetString() == "amp");
    Assert(amp.GetProperty("binaries").EnumerateArray().Select(value => value.GetString()).SequenceEqual(["amp"]), "Amp descriptor should expose the amp binary");
    Assert(amp.GetProperty("target_paths").GetArrayLength() == 2, "Amp descriptor should expose settings and secrets paths");
    Assert(amp.GetProperty("capabilities").EnumerateArray().Select(value => value.GetString()).SequenceEqual(["guide", "diff"]), "Amp descriptor should expose read-only diff");

    using var guide = ToJsonDocument(adapter.Handle("/agents/codex/guide", "GET"));
    Assert(guide.RootElement.GetProperty("guide").GetProperty("tool").GetString() == "codex", "Guide endpoint should return the requested agent");
    Assert(guide.RootElement.GetProperty("guide").GetProperty("capabilities").EnumerateArray().Select(value => value.GetString()).SequenceEqual(["guide", "diff", "install"]), "Guide endpoint should mirror Codex write capabilities");

    using var ampGuide = ToJsonDocument(adapter.Handle("/agents/amp/guide", "GET"));
    Assert(ampGuide.RootElement.GetProperty("guide").GetProperty("tool").GetString() == "amp", "Amp guide endpoint should return Amp");

    using var diff = ToJsonDocument(adapter.Handle("/agents/codex/diff", "POST"));
    var diffFile = diff.RootElement.GetProperty("plan").GetProperty("files")[0];
    Assert(diffFile.GetProperty("has_changes").GetBoolean(), "Codex diff preview should report the pending config change");
    Assert(!diffFile.GetProperty("after").GetString()!.Contains("smoke-management-key", StringComparison.Ordinal), "Codex diff preview should redact management keys");
    Assert(diff.RootElement.GetProperty("status").GetProperty("platform_support").GetString() == "supported", "Diff status should expose read-only Windows support");

    using var install = ToJsonDocument(adapter.Handle("/agents/codex/install", "POST"));
    Assert(install.RootElement.GetProperty("summary").GetString()?.Contains("installed", StringComparison.OrdinalIgnoreCase) == true, "Codex install should succeed");
    Assert(install.RootElement.GetProperty("status").GetProperty("configured").GetBoolean(), "Codex install should mark the adapter configured");
    Assert(install.RootElement.GetProperty("status").GetProperty("rollback_available").GetBoolean(), "Codex install should create a rollback backup");
    var installedConfig = File.ReadAllText(configPath);
    Assert(installedConfig.Contains("model_provider = \"quotio\"", StringComparison.Ordinal), "Codex install should point Codex at Quotio");
    Assert(installedConfig.Contains("base_url = \"http://127.0.0.1:8787/v1\"", StringComparison.Ordinal), "Codex install should normalize the proxy endpoint");
    Assert(installedConfig.Contains("experimental_bearer_token = \"smoke-management-key\"", StringComparison.Ordinal), "Codex install should write the configured key to disk");

    using var rollback = ToJsonDocument(adapter.Handle("/agents/codex/rollback", "POST"));
    Assert(rollback.RootElement.GetProperty("summary").GetString()?.Contains("restored", StringComparison.OrdinalIgnoreCase) == true, "Codex rollback should restore the latest backup");
    Assert(File.ReadAllText(configPath) == originalCodexConfig, "Codex rollback should restore the pre-install config");

    using var afterRollbackList = ToJsonDocument(adapter.Handle("/agents", "GET"));
    var afterRollbackCodex = afterRollbackList.RootElement.GetProperty("agents").EnumerateArray().First(agent => agent.GetProperty("id").GetString() == "codex");
    Assert(afterRollbackCodex.GetProperty("rollback_available").GetBoolean(), "Codex should keep rollback available after creating a pre-restore backup");

    using var ampInstall = ToJsonDocument(adapter.Handle("/agents/amp/install", "POST"));
    Assert(ampInstall.RootElement.GetProperty("summary").GetString()?.Contains("disabled", StringComparison.OrdinalIgnoreCase) == true, "Amp install should stay disabled");
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
    Environment.SetEnvironmentVariable("QUOTIO_PROXY_BINARY", null);
    Environment.SetEnvironmentVariable("QUOTIO_PROXY_ARGS", null);
}

static void Assert(bool condition, string message)
{
    if (!condition)
    {
        throw new InvalidOperationException(message);
    }
}

static void RunRuntimeChildServer(string host, int port, int lifetimeSeconds)
{
    var listener = new TcpListener(IPAddress.Parse(host), port);
    listener.Start();
    Thread.Sleep(TimeSpan.FromSeconds(lifetimeSeconds));
    listener.Stop();
}
