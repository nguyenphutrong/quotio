using System.Text.Json;
using System.Text;
using System.Net;
using System.Net.Sockets;
using System.Diagnostics;
using Quotio.Windows;

if (args.Contains("--runtime-child", StringComparer.Ordinal))
{
    WriteRuntimeChildPidFile();
    Thread.Sleep(TimeSpan.FromSeconds(10));
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
    ["QUOTIO_WINDOWS_LOG_DIR"] = Environment.GetEnvironmentVariable("QUOTIO_WINDOWS_LOG_DIR"),
    ["QUOTIO_WINDOWS_CRASH_REPORT_DIR"] = Environment.GetEnvironmentVariable("QUOTIO_WINDOWS_CRASH_REPORT_DIR"),
    ["QUOTIO_WINDOWS_CRASH_UPLOAD_URL"] = Environment.GetEnvironmentVariable("QUOTIO_WINDOWS_CRASH_UPLOAD_URL"),
    ["QUOTIO_WINDOWS_UPDATE_REPOSITORY_URL"] = Environment.GetEnvironmentVariable("QUOTIO_WINDOWS_UPDATE_REPOSITORY_URL"),
    ["QUOTIO_WINDOWS_UPDATE_CHANNEL"] = Environment.GetEnvironmentVariable("QUOTIO_WINDOWS_UPDATE_CHANNEL"),
    ["USERPROFILE"] = Environment.GetEnvironmentVariable("USERPROFILE"),
    ["LOCALAPPDATA"] = Environment.GetEnvironmentVariable("LOCALAPPDATA")
};

try
{
    RunConfigSmoke();
    RunCredentialStoreSmoke();
    RunNativePreferencesSmoke();
    RunWindowsStartupServiceSmoke();
    RunDesktopUiSourceSmoke();
    RunBootstrapSmoke();
    RunSingleInstanceSmoke();
    RunWindowPlacementSmoke();
    RunDiagnosticLogSmoke();
    RunCrashReporterSmoke();
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
        "Quotio/WindowsUpdateRepositoryUrl" => " https://github.com/example/quotio ",
        "Quotio/WindowsUpdateChannel" => " beta ",
        _ => null
    });

    Assert(fallbackConfig.DesktopUiDevServer == "https://credential-ui.example", "Credential fallback should trim dev server");
    Assert(fallbackConfig.ManagementBaseUrl == "http://credential-management.example", "Credential fallback should trim management base URL");
    Assert(fallbackConfig.ManagementKey == "credential-management-key", "Credential fallback should trim management key");
    Assert(fallbackConfig.ProxyEndpoint == "http://127.0.0.1:9393", "Credential fallback should provide proxy endpoint");
    Assert(fallbackConfig.ServerListen == "127.0.0.1:9393", "ServerListen should derive from proxy endpoint authority");
    Assert(fallbackConfig.WindowsUpdateRepositoryUrl == "https://github.com/example/quotio", "Credential fallback should trim update repository URL");
    Assert(fallbackConfig.WindowsUpdateChannel == "beta", "Credential fallback should normalize update channel");

    Environment.SetEnvironmentVariable("QUOTIO_DESKTOP_UI_DEV_SERVER", " http://localhost:5173 ");
    Environment.SetEnvironmentVariable("QUOTIO_MANAGEMENT_BASE_URL", " http://localhost:8386 ");
    Environment.SetEnvironmentVariable("QUOTIO_MANAGEMENT_KEY", " env-management-key ");
    Environment.SetEnvironmentVariable("QUOTIO_PROXY_ENDPOINT", " http://127.0.0.1:8484 ");
    Environment.SetEnvironmentVariable("QUOTIO_WINDOWS_UPDATE_REPOSITORY_URL", " https://github.com/env/quotio ");
    Environment.SetEnvironmentVariable("QUOTIO_WINDOWS_UPDATE_CHANNEL", " stable ");

    var envConfig = new WindowsHostConfig(_ => "credential-value");
    Assert(envConfig.DesktopUiDevServer == "http://localhost:5173", "Environment dev server should win over credentials");
    Assert(envConfig.ManagementBaseUrl == "http://localhost:8386", "Environment base URL should win over credentials");
    Assert(envConfig.ManagementKey == "env-management-key", "Environment management key should win over credentials");
    Assert(envConfig.ProxyEndpoint == "http://127.0.0.1:8484", "Environment proxy endpoint should win over credentials");
    Assert(envConfig.ServerListen == "127.0.0.1:8484", "ServerListen should use environment proxy endpoint");
    Assert(envConfig.WindowsUpdateRepositoryUrl == "https://github.com/env/quotio", "Environment update repository should win over credentials");
    Assert(envConfig.WindowsUpdateChannel == "stable", "Environment update channel should win over credentials");
}

static void RunCredentialStoreSmoke()
{
    if (!OperatingSystem.IsWindows())
    {
        return;
    }

    var targetName = $"Quotio/Smoke/{Guid.NewGuid():N}";
    WindowsCredentialStore.DeleteGenericCredential(targetName);

    WindowsCredentialStore.WriteGenericCredential(targetName, " smoke-secret ");
    Assert(
        WindowsCredentialStore.TryReadGenericCredential(targetName) == " smoke-secret ",
        "Credential store should round-trip generic credentials"
    );

    WindowsCredentialStore.DeleteGenericCredential(targetName);
    Assert(
        WindowsCredentialStore.TryReadGenericCredential(targetName) is null,
        "Credential store delete should remove generic credentials"
    );
}

static void RunDesktopUiSourceSmoke()
{
    ClearEnvironment();
    Environment.SetEnvironmentVariable("QUOTIO_DESKTOP_UI_DEV_SERVER", " http://localhost:5173 ");
    var devServerSource = DesktopUiSource.Resolve(new WindowsHostConfig(_ => null));
    Assert(devServerSource?.AbsoluteUri == "http://localhost:5173/", "Desktop UI resolver should prefer a valid dev server");

    var bundledDirectory = Path.Combine(AppContext.BaseDirectory, "desktop-ui");
    var bundledIndex = Path.Combine(bundledDirectory, "index.html");
    Directory.CreateDirectory(bundledDirectory);
    File.WriteAllText(bundledIndex, "<!doctype html><title>Quotio smoke</title>");

    Environment.SetEnvironmentVariable("QUOTIO_DESKTOP_UI_DEV_SERVER", "not a uri");
    var invalidDevFallback = DesktopUiSource.Resolve(new WindowsHostConfig(_ => null));
    Assert(invalidDevFallback?.IsFile == true, "Desktop UI resolver should fall back to bundled UI when dev server is invalid");
    var fallbackPath = invalidDevFallback?.LocalPath ?? "";
    Assert(Path.GetFullPath(fallbackPath) == Path.GetFullPath(bundledIndex), "Desktop UI resolver should point at bundled index.html");

    Environment.SetEnvironmentVariable("QUOTIO_DESKTOP_UI_DEV_SERVER", null);
    var bundledSource = DesktopUiSource.Resolve(new WindowsHostConfig(_ => null));
    Assert(Path.GetFullPath(bundledSource!.LocalPath) == Path.GetFullPath(bundledIndex), "Desktop UI resolver should use bundled index.html without dev server");
}

static void RunBootstrapSmoke()
{
    ClearEnvironment();
    Environment.SetEnvironmentVariable("QUOTIO_PROXY_ENDPOINT", "http://127.0.0.1:8585");
    var remoteBootstrap = DesktopUiSource.Bootstrap(new WindowsHostConfig(_ => null));

    Assert(remoteBootstrap.UiEnabled, "Windows bootstrap should enable shared UI");
    Assert(remoteBootstrap.Platform == "windows", "Windows bootstrap should identify the platform");
    Assert(remoteBootstrap.BridgeVersion == Quotio.Contract.QuotioContract.Version, "Windows bootstrap should expose the generated contract version");
    Assert(remoteBootstrap.ServerListen == "127.0.0.1:8585", "Windows bootstrap should expose server listen authority");
    Assert(remoteBootstrap.OperatingMode == "remote", "Windows bootstrap should default to remote mode without a local runtime");
    AssertExactBoolDictionary(remoteBootstrap.Features, new Dictionary<string, bool>
    {
        ["overview"] = false,
        ["providers"] = false,
        ["quota"] = false,
        ["usage"] = false,
        ["virtualModels"] = false,
        ["models"] = false,
        ["agents"] = false,
        ["apiKeys"] = false,
        ["logs"] = false,
        ["settings"] = true,
        ["about"] = true
    }, "Windows bootstrap features");
    AssertExactBoolDictionary(remoteBootstrap.Capabilities, new Dictionary<string, bool>
    {
        ["supportsLocalProxy"] = false,
        ["supportsProxyControl"] = false,
        ["supportsPortConfig"] = false,
        ["supportsCliOAuth"] = false,
        ["supportsAgentConfig"] = false,
        ["supportsRemoteConnections"] = true,
        ["supportsCredentialStorage"] = true,
        ["supportsManagementBridge"] = false,
        ["supportsNativeOnboarding"] = false,
        ["supportsNativePreferences"] = true,
        ["supportsAppearanceSync"] = true,
        ["supportsRequestLogSettings"] = true,
        ["supportsModelSettings"] = true,
        ["supportsApiKeyManagement"] = true,
        ["supportsVirtualModelManagement"] = true,
        ["supportsUpdates"] = true
    }, "Windows bootstrap capabilities");

    var runtimeBinary = Process.GetCurrentProcess().MainModule?.FileName;
    Assert(!string.IsNullOrWhiteSpace(runtimeBinary), "Smoke process path should be available");
    Environment.SetEnvironmentVariable("QUOTIO_PROXY_BINARY", runtimeBinary);
    var localBootstrap = DesktopUiSource.Bootstrap(new WindowsHostConfig(_ => null));

    Assert(localBootstrap.OperatingMode == "local", "Windows bootstrap should allow local mode when a runtime binary exists");
    Assert(localBootstrap.Features["agents"], "Windows bootstrap should expose agents only in local mode");
    Assert(localBootstrap.Capabilities["supportsLocalProxy"], "Windows bootstrap should expose local proxy only with a runtime binary");
    Assert(localBootstrap.Capabilities["supportsProxyControl"], "Windows bootstrap should expose proxy controls only with a runtime binary");
    Assert(localBootstrap.Capabilities["supportsPortConfig"], "Windows bootstrap should expose port config only with a runtime binary");
    Assert(localBootstrap.Capabilities["supportsCliOAuth"], "Windows bootstrap should expose CLI OAuth only with a runtime binary");
    Assert(localBootstrap.Capabilities["supportsAgentConfig"], "Windows bootstrap should expose agent config only with a runtime binary");
    Assert(localBootstrap.Capabilities["supportsManagementBridge"], "Windows bootstrap should expose management routes in local runtime mode");

    var remotePreferencesPath = Path.Combine(Path.GetTempPath(), $"quotio-windows-remote-bootstrap-{Guid.NewGuid():N}.json");
    var remotePreferencesStore = new WindowsNativePreferencesStore(remotePreferencesPath);
    remotePreferencesStore.Save(new WindowsNativePreferencesState { OperatingMode = "remote" });
    var remoteRuntimeBootstrap = DesktopUiSource.Bootstrap(new WindowsHostConfig(_ => null), remotePreferencesStore);
    Assert(remoteRuntimeBootstrap.OperatingMode == "remote", "Windows bootstrap should preserve remote mode when a runtime binary exists");
    Assert(remoteRuntimeBootstrap.Capabilities["supportsLocalProxy"], "Windows bootstrap should still allow switching back to local mode when a runtime binary exists");
    Assert(!remoteRuntimeBootstrap.Capabilities["supportsProxyControl"], "Windows bootstrap should hide proxy controls in remote mode");
    Assert(!remoteRuntimeBootstrap.Capabilities["supportsManagementBridge"], "Windows bootstrap should hide management routes in remote mode before remote configuration");

    var configuredRemoteBootstrap = DesktopUiSource.Bootstrap(new WindowsHostConfig(target => target == "Quotio/ManagementBaseUrl"
        ? "http://127.0.0.1:8787"
        : null), remotePreferencesStore);
    Assert(configuredRemoteBootstrap.OperatingMode == "remote", "Windows bootstrap should stay in remote mode when only remote management URL is configured");
    Assert(configuredRemoteBootstrap.Features["overview"], "Windows bootstrap should expose management routes when remote management URL is configured");
    Assert(configuredRemoteBootstrap.Capabilities["supportsManagementBridge"], "Windows bootstrap should treat remote management URL as bridge-ready without requiring a key");
}

static void RunNativePreferencesSmoke()
{
    var preferencesPath = Path.Combine(Path.GetTempPath(), $"quotio-windows-preferences-{Guid.NewGuid():N}.json");
    var store = new WindowsNativePreferencesStore(preferencesPath);
    var config = new WindowsHostConfig(target => target == "Quotio/ProxyEndpoint"
        ? "http://127.0.0.1:9393"
        : null);

    using var update = JsonDocument.Parse(
        """
        {
          "language": "vi",
          "appearance": "dark",
          "operatingMode": "remote",
          "launchAtLogin": false,
          "hideSensitiveInfo": true,
          "totalUsageMode": "combined",
          "modelAggregationMode": "average",
          "notificationsEnabled": false,
          "notifyOnQuotaLow": false,
          "notifyOnCooling": true,
          "notifyOnProxyCrash": false,
          "autoCheckUpdates": false,
          "updateChannel": "beta",
          "proxyPort": 9494
        }
        """
    );

    var state = store.Update(update.RootElement, config);
    Assert(state.Language == "vi", "Windows preferences should persist language");
    Assert(state.Appearance == "dark", "Windows preferences should persist appearance");
    Assert(state.OperatingMode == "remote", "Windows preferences should persist operating mode");
    Assert(state.HideSensitiveInfo, "Windows preferences should persist privacy settings");
    Assert(state.TotalUsageMode == "combined", "Windows preferences should persist usage mode");
    Assert(state.ModelAggregationMode == "average", "Windows preferences should persist model aggregation mode");
    Assert(!state.NotificationsEnabled, "Windows preferences should persist notification enablement");
    Assert(!state.NotifyOnQuotaLow, "Windows preferences should persist quota notification settings");
    Assert(state.NotifyOnCooling, "Windows preferences should persist cooling notification settings");
    Assert(!state.NotifyOnProxyCrash, "Windows preferences should persist proxy crash notification settings");
    Assert(!state.AutoCheckUpdates, "Windows preferences should persist update check settings");
    Assert(state.UpdateChannel == "beta", "Windows preferences should persist update channel");

    var reloaded = store.Load();
    Assert(reloaded.Language == "vi", "Windows preferences should reload from disk");
    Assert(reloaded.UpdateChannel == "beta", "Windows preferences should reload update channel from disk");

    var updates = new WindowsUpdateService(config, store);
    var updateSnapshot = updates.Snapshot();
    Assert(!updateSnapshot.UpdatesSupported, "Windows updater should require a Velopack-installed build");
    Assert(updateSnapshot.UpdateChannel == "beta", "Windows updater should use persisted channel");
    Assert(!updateSnapshot.CanCheckForUpdates, "Windows updater should not check outside a Velopack-installed build");

    if (OperatingSystem.IsWindows())
    {
        Assert(
            WindowsCredentialStore.TryReadGenericCredential("Quotio/ProxyEndpoint") == "http://127.0.0.1:9494",
            "Windows preferences should persist proxy port to Credential Manager"
        );
        WindowsCredentialStore.DeleteGenericCredential("Quotio/ProxyEndpoint");
    }
}

static void RunWindowsStartupServiceSmoke()
{
    Assert(
        WindowsStartupService.BuildStartupCommand(@"C:\Program Files\Quotio\Quotio.exe") == @"""C:\Program Files\Quotio\Quotio.exe""",
        "Windows startup command should quote executable paths"
    );

    if (!OperatingSystem.IsWindows())
    {
        WindowsStartupService.SetEnabled(false);
        Assert(!WindowsStartupService.IsEnabled(), "Non-Windows startup registration should stay disabled");
        return;
    }

    var originalCommand = WindowsStartupService.ReadRegisteredCommand();
    try
    {
        WindowsStartupService.SetEnabled(true);
        Assert(WindowsStartupService.IsEnabled(), "Windows startup registration should enable launch at login");

        WindowsStartupService.SetEnabled(false);
        Assert(!WindowsStartupService.IsEnabled(), "Windows startup registration should disable launch at login");
    }
    finally
    {
        WindowsStartupService.RestoreRegisteredCommand(originalCommand);
    }
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

static void RunDiagnosticLogSmoke()
{
    var logDir = Path.Combine(Path.GetTempPath(), $"quotio-windows-log-{Guid.NewGuid():N}");
    Environment.SetEnvironmentVariable("QUOTIO_WINDOWS_LOG_DIR", logDir);

    DiagnosticLog.Info("smoke info");
    DiagnosticLog.Error("smoke error", new InvalidOperationException("expected smoke exception"));

    Assert(File.Exists(DiagnosticLog.LogFilePath), "Diagnostic log should create a log file");
    var contents = File.ReadAllText(DiagnosticLog.LogFilePath);
    Assert(contents.Contains("[INFO] smoke info", StringComparison.Ordinal), "Diagnostic log should write info entries");
    Assert(contents.Contains("[ERROR] smoke error", StringComparison.Ordinal), "Diagnostic log should write error entries");
    Assert(contents.Contains("expected smoke exception", StringComparison.Ordinal), "Diagnostic log should include exception details");
}

static void RunSingleInstanceSmoke()
{
    if (!OperatingSystem.IsWindows())
    {
        return;
    }

    var instanceName = $"dev.quotio.desktop.windows.smoke.{Guid.NewGuid():N}";
    using var activationReceived = new ManualResetEventSlim(false);

    using (var primary = new SingleInstanceGuard(instanceName))
    {
        Assert(primary.IsPrimary, "First Windows instance should become primary");
        primary.ActivationRequested += (_, _) => activationReceived.Set();
        primary.StartListening();

        using (var secondary = new SingleInstanceGuard(instanceName))
        {
            Assert(!secondary.IsPrimary, "Second Windows instance should not become primary");
            secondary.SignalPrimary();
            Assert(activationReceived.Wait(TimeSpan.FromSeconds(2)), "Second Windows instance should signal the primary instance");
        }
    }

    using var afterPrimaryExit = new SingleInstanceGuard(instanceName);
    Assert(afterPrimaryExit.IsPrimary, "Windows instance ownership should be released after primary exit");
}

static void RunRuntimeControllerSmoke()
{
    ClearEnvironment();
    Environment.SetEnvironmentVariable("QUOTIO_PROXY_BINARY", Environment.ProcessPath);
    Environment.SetEnvironmentVariable("QUOTIO_PROXY_ENDPOINT", "http://127.0.0.1:8686");
    Environment.SetEnvironmentVariable("QUOTIO_PROXY_ARGS", "--runtime-child-server 127.0.0.1 8686");
    var runtimePidFile = Path.Combine(Path.GetTempPath(), $"quotio-runtime-{Guid.NewGuid():N}.pid");
    Environment.SetEnvironmentVariable("QUOTIO_RUNTIME_CHILD_PID_FILE", runtimePidFile);

    using var runtime = new RuntimeProcessController(new WindowsHostConfig(_ => null));
    var stopped = runtime.Status();
    Assert(stopped.State == "stopped", "Runtime should start stopped");
    Assert(stopped.Endpoint is null, "Stopped runtime should not expose an endpoint");

    var started = runtime.Start();
    Assert(started.State == "managed", "Runtime start should return managed status");
    Assert(started.Endpoint == "http://127.0.0.1:8686", "Runtime start should expose configured endpoint");
    var firstRuntimePid = WaitForPidFile(runtimePidFile);
    Assert(ProcessIsRunning(firstRuntimePid), "Runtime child should be alive after start");

    var restarted = runtime.Restart();
    Assert(restarted.State == "managed", "Runtime restart should return managed status");
    Assert(restarted.Endpoint == "http://127.0.0.1:8686", "Runtime restart should preserve configured endpoint");
    Assert(WaitForProcess(firstRuntimePid, running: false), "Runtime restart should kill the previous child process");
    var secondRuntimePid = WaitForPidFile(runtimePidFile, firstRuntimePid);
    Assert(ProcessIsRunning(secondRuntimePid), "Runtime child should be alive after restart");

    var stoppedAgain = runtime.Stop();
    Assert(stoppedAgain.State == "stopped", "Runtime stop should return stopped status");
    Assert(stoppedAgain.Endpoint is null, "Runtime stop should clear endpoint");
    Assert(WaitForProcess(secondRuntimePid, running: false), "Runtime stop should kill the child process");

    Environment.SetEnvironmentVariable("QUOTIO_PROXY_ENDPOINT", "http://127.0.0.1:8699");
    Environment.SetEnvironmentVariable("QUOTIO_PROXY_ARGS", "--runtime-child");
    var unhealthyPidFile = Path.Combine(Path.GetTempPath(), $"quotio-runtime-unhealthy-{Guid.NewGuid():N}.pid");
    Environment.SetEnvironmentVariable("QUOTIO_RUNTIME_CHILD_PID_FILE", unhealthyPidFile);
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
        var unhealthyPid = WaitForPidFile(unhealthyPidFile);
        Assert(WaitForProcess(unhealthyPid, running: false), "Runtime start failure should kill the unreachable child process");
    }

    Environment.SetEnvironmentVariable("QUOTIO_PROXY_ENDPOINT", "http://127.0.0.1:8687");
    Environment.SetEnvironmentVariable("QUOTIO_PROXY_ARGS", "--runtime-child-server 127.0.0.1 8687 1");
    Environment.SetEnvironmentVariable("QUOTIO_RUNTIME_CHILD_PID_FILE", null);
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

static void RunCrashReporterSmoke()
{
    var reportDirectory = Path.Combine(Path.GetTempPath(), $"quotio-crash-reports-{Guid.NewGuid():N}");
    using var listener = new TcpListener(IPAddress.Loopback, 0);
    listener.Start();
    var port = ((IPEndPoint)listener.LocalEndpoint).Port;
    var requestTask = Task.Run(() => ReadHttpRequestBody(listener));

    Environment.SetEnvironmentVariable("QUOTIO_WINDOWS_CRASH_REPORT_DIR", reportDirectory);
    Environment.SetEnvironmentVariable("QUOTIO_WINDOWS_CRASH_UPLOAD_URL", $"http://127.0.0.1:{port}/crashes");

    var result = WindowsCrashReporter.Capture(
        new InvalidOperationException("management key=smoke-secret should be redacted"),
        "smoke"
    );

    Assert(result.UploadAttempted, "Crash reporter should attempt upload when an upload URL is configured");
    Assert(result.UploadSucceeded, "Crash reporter should upload to the configured endpoint");
    Assert(File.Exists(result.ReportPath), "Crash reporter should write a local report before upload");

    var payload = File.ReadAllText(result.ReportPath);
    Assert(payload.Contains("\"source\":\"smoke\"", StringComparison.Ordinal), "Crash report should include source");
    Assert(!payload.Contains("smoke-secret", StringComparison.Ordinal), "Crash report should redact management keys");
    Assert(payload.Contains("[redacted]", StringComparison.Ordinal), "Crash report should preserve redaction marker");

    var uploadedPayload = requestTask.GetAwaiter().GetResult();
    Assert(uploadedPayload == payload.TrimEnd(), "Crash reporter should upload the same JSON payload written to disk");
}

static void RunAgentAdapterSmoke()
{
    ClearEnvironment();
    Environment.SetEnvironmentVariable("QUOTIO_PROXY_ENDPOINT", "http://127.0.0.1:8787");
    Environment.SetEnvironmentVariable("QUOTIO_MANAGEMENT_KEY", "smoke-management-key");

    var smokeRoot = Path.Combine(Path.GetTempPath(), $"quotio-windows-agents-{Guid.NewGuid():N}");
    var home = Path.Combine(smokeRoot, "home");
    var localAppData = Path.Combine(smokeRoot, "local-app-data");
    Directory.CreateDirectory(Path.Combine(home, ".claude"));
    Directory.CreateDirectory(Path.Combine(home, ".codex"));
    Directory.CreateDirectory(Path.Combine(home, ".config", "amp"));
    Directory.CreateDirectory(Path.Combine(home, ".factory"));
    Directory.CreateDirectory(Path.Combine(home, "Documents", "PowerShell"));
    Directory.CreateDirectory(Path.Combine(home, ".local", "share", "amp"));
    Directory.CreateDirectory(Path.Combine(localAppData, "opencode"));
    Directory.CreateDirectory(localAppData);
    Environment.SetEnvironmentVariable("USERPROFILE", home);
    Environment.SetEnvironmentVariable("LOCALAPPDATA", localAppData);

    var configPath = Path.Combine(home, ".codex", "config.toml");
    const string originalCodexConfig = "model = \"gpt-4.1\"\nmodel_provider = \"openai\"\n\n[model_providers.openai]\nname = \"OpenAI\"\n";
    File.WriteAllText(configPath, originalCodexConfig);

    var openCodeConfigPath = Path.Combine(localAppData, "opencode", "opencode.json");
    const string originalOpenCodeConfig = """
    {
      "$schema": "https://opencode.ai/config.json",
      "provider": {
        "anthropic": {
          "name": "Anthropic"
        }
      },
      "theme": "system"
    }
    """;
    File.WriteAllText(openCodeConfigPath, originalOpenCodeConfig);

    var factoryConfigPath = Path.Combine(home, ".factory", "config.json");
    const string originalFactoryConfig = """
    {
      "custom_models": [
        {
          "model": "existing-model",
          "model_display_name": "Existing Model",
          "base_url": "https://example.invalid/v1",
          "api_key": "existing-key",
          "provider": "openai"
        }
      ]
    }
    """;
    File.WriteAllText(factoryConfigPath, originalFactoryConfig);

    var claudeConfigPath = Path.Combine(home, ".claude", "settings.json");
    const string originalClaudeConfig = """
    {
      "env": {
        "MCP_API_KEY": "preserve-me"
      },
      "permissions": {
        "allow": [
          "Bash(git status:*)"
        ]
      },
      "model": "claude-sonnet-4-5"
    }
    """;
    File.WriteAllText(claudeConfigPath, originalClaudeConfig);

    var ampSettingsPath = Path.Combine(home, ".config", "amp", "settings.json");
    var ampSecretsPath = Path.Combine(home, ".local", "share", "amp", "secrets.json");
    const string originalAmpSettings = """
    {
      "amp.url": "https://ampcode.com"
    }
    """;
    const string originalAmpSecrets = """
    {
      "apiKey@https://ampcode.com": "existing-amp-key"
    }
    """;
    File.WriteAllText(ampSettingsPath, originalAmpSettings);
    File.WriteAllText(ampSecretsPath, originalAmpSecrets);

    var geminiProfilePath = Path.Combine(home, "Documents", "PowerShell", "Microsoft.PowerShell_profile.ps1");
    const string originalGeminiProfile = """
    Set-Alias gs git-status
    """;
    File.WriteAllText(geminiProfilePath, originalGeminiProfile);

    var adapter = new WindowsAgentAdapter(
        new WindowsHostConfig(_ => null),
        new WindowsCodexConfigPatcher(home, Path.Combine(localAppData, "Quotio", "Codex")),
        new WindowsOpenCodeConfigPatcher(localAppData),
        new WindowsFactoryDroidConfigPatcher(home),
        new WindowsClaudeCodeConfigPatcher(home),
        new WindowsAmpConfigPatcher(home),
        new WindowsGeminiConfigPatcher(home)
    );
    using var list = ToJsonDocument(adapter.Handle("/agents", "GET"));
    var agents = list.RootElement.GetProperty("agents");
    Assert(agents.GetArrayLength() >= 6, "Windows agents endpoint should return descriptors");

    var codex = agents.EnumerateArray().First(agent => agent.GetProperty("id").GetString() == "codex");
    Assert(codex.GetProperty("platform_support").GetString() == "supported", "Codex descriptor should expose read-only Windows support");
    Assert(codex.GetProperty("capabilities").EnumerateArray().Select(value => value.GetString()).SequenceEqual(["guide", "diff", "install"]), "Codex descriptor should expose install after Windows backup validation");
    Assert(!codex.GetProperty("rollback_available").GetBoolean(), "Codex should not claim rollback before a backup exists");

    var gemini = agents.EnumerateArray().First(agent => agent.GetProperty("id").GetString() == "gemini-cli");
    Assert(gemini.GetProperty("platform_support").GetString() == "supported", "Gemini descriptor should expose Windows support");
    Assert(gemini.GetProperty("target_paths").GetArrayLength() == 1, "Gemini descriptor should expose the PowerShell profile path");
    Assert(gemini.GetProperty("capabilities").EnumerateArray().Select(value => value.GetString()).SequenceEqual(["guide", "diff", "install"]), "Gemini descriptor should expose install after PowerShell backup validation");

    var amp = agents.EnumerateArray().First(agent => agent.GetProperty("id").GetString() == "amp");
    Assert(amp.GetProperty("binaries").EnumerateArray().Select(value => value.GetString()).SequenceEqual(["amp"]), "Amp descriptor should expose the amp binary");
    Assert(amp.GetProperty("target_paths").GetArrayLength() == 2, "Amp descriptor should expose settings and secrets paths");
    Assert(amp.GetProperty("capabilities").EnumerateArray().Select(value => value.GetString()).SequenceEqual(["guide", "diff", "install"]), "Amp descriptor should expose install after Windows backup validation");

    var openCode = agents.EnumerateArray().First(agent => agent.GetProperty("id").GetString() == "opencode");
    Assert(openCode.GetProperty("capabilities").EnumerateArray().Select(value => value.GetString()).SequenceEqual(["guide", "diff", "install"]), "OpenCode descriptor should expose install after Windows backup validation");

    var factoryDroid = agents.EnumerateArray().First(agent => agent.GetProperty("id").GetString() == "factory-droid");
    Assert(factoryDroid.GetProperty("capabilities").EnumerateArray().Select(value => value.GetString()).SequenceEqual(["guide", "diff", "install"]), "Factory Droid descriptor should expose install after Windows backup validation");

    var claudeCode = agents.EnumerateArray().First(agent => agent.GetProperty("id").GetString() == "claude-code");
    Assert(claudeCode.GetProperty("capabilities").EnumerateArray().Select(value => value.GetString()).SequenceEqual(["guide", "diff", "install"]), "Claude Code descriptor should expose install after Windows backup validation");

    using var guide = ToJsonDocument(adapter.Handle("/agents/codex/guide", "GET"));
    Assert(guide.RootElement.GetProperty("guide").GetProperty("tool").GetString() == "codex", "Guide endpoint should return the requested agent");
    Assert(guide.RootElement.GetProperty("guide").GetProperty("capabilities").EnumerateArray().Select(value => value.GetString()).SequenceEqual(["guide", "diff", "install"]), "Guide endpoint should mirror Codex write capabilities");

    using var ampGuide = ToJsonDocument(adapter.Handle("/agents/amp/guide", "GET"));
    Assert(ampGuide.RootElement.GetProperty("guide").GetProperty("tool").GetString() == "amp", "Amp guide endpoint should return Amp");
    Assert(ampGuide.RootElement.GetProperty("guide").GetProperty("capabilities").EnumerateArray().Select(value => value.GetString()).SequenceEqual(["guide", "diff", "install"]), "Amp guide endpoint should mirror write capabilities");

    using var openCodeGuide = ToJsonDocument(adapter.Handle("/agents/opencode/guide", "GET"));
    Assert(openCodeGuide.RootElement.GetProperty("guide").GetProperty("capabilities").EnumerateArray().Select(value => value.GetString()).SequenceEqual(["guide", "diff", "install"]), "OpenCode guide endpoint should mirror write capabilities");

    using var factoryDroidGuide = ToJsonDocument(adapter.Handle("/agents/factory-droid/guide", "GET"));
    Assert(factoryDroidGuide.RootElement.GetProperty("guide").GetProperty("capabilities").EnumerateArray().Select(value => value.GetString()).SequenceEqual(["guide", "diff", "install"]), "Factory Droid guide endpoint should mirror write capabilities");

    using var claudeCodeGuide = ToJsonDocument(adapter.Handle("/agents/claude-code/guide", "GET"));
    Assert(claudeCodeGuide.RootElement.GetProperty("guide").GetProperty("capabilities").EnumerateArray().Select(value => value.GetString()).SequenceEqual(["guide", "diff", "install"]), "Claude Code guide endpoint should mirror write capabilities");

    using var geminiGuide = ToJsonDocument(adapter.Handle("/agents/gemini-cli/guide", "GET"));
    Assert(geminiGuide.RootElement.GetProperty("guide").GetProperty("capabilities").EnumerateArray().Select(value => value.GetString()).SequenceEqual(["guide", "diff", "install"]), "Gemini guide endpoint should mirror write capabilities");

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

    using var openCodeDiff = ToJsonDocument(adapter.Handle("/agents/opencode/diff", "POST"));
    var openCodeDiffFile = openCodeDiff.RootElement.GetProperty("plan").GetProperty("files")[0];
    Assert(openCodeDiffFile.GetProperty("has_changes").GetBoolean(), "OpenCode diff preview should report the pending config change");
    Assert(!openCodeDiffFile.GetProperty("after").GetString()!.Contains("smoke-management-key", StringComparison.Ordinal), "OpenCode diff preview should redact management keys");
    Assert(openCodeDiffFile.GetProperty("after").GetString()!.Contains("\"quotio\"", StringComparison.Ordinal), "OpenCode diff preview should include provider.quotio");

    using var openCodeInstall = ToJsonDocument(adapter.Handle("/agents/opencode/install", "POST"));
    Assert(openCodeInstall.RootElement.GetProperty("summary").GetString()?.Contains("installed", StringComparison.OrdinalIgnoreCase) == true, "OpenCode install should succeed");
    Assert(openCodeInstall.RootElement.GetProperty("status").GetProperty("configured").GetBoolean(), "OpenCode install should mark the adapter configured");
    Assert(openCodeInstall.RootElement.GetProperty("status").GetProperty("rollback_available").GetBoolean(), "OpenCode install should create a rollback backup");
    var installedOpenCodeConfig = File.ReadAllText(openCodeConfigPath);
    Assert(installedOpenCodeConfig.Contains("\"quotio\"", StringComparison.Ordinal), "OpenCode install should merge provider.quotio");
    Assert(installedOpenCodeConfig.Contains("\"anthropic\"", StringComparison.Ordinal), "OpenCode install should preserve existing providers");
    Assert(installedOpenCodeConfig.Contains("\"theme\": \"system\"", StringComparison.Ordinal), "OpenCode install should preserve top-level settings");
    Assert(installedOpenCodeConfig.Contains("\"baseURL\": \"http://127.0.0.1:8787/v1\"", StringComparison.Ordinal), "OpenCode install should normalize the proxy endpoint");
    Assert(installedOpenCodeConfig.Contains("\"apiKey\": \"smoke-management-key\"", StringComparison.Ordinal), "OpenCode install should write the configured key to disk");

    using var openCodeRollback = ToJsonDocument(adapter.Handle("/agents/opencode/rollback", "POST"));
    Assert(openCodeRollback.RootElement.GetProperty("summary").GetString()?.Contains("restored", StringComparison.OrdinalIgnoreCase) == true, "OpenCode rollback should restore the latest backup");
    Assert(JsonEquivalent(File.ReadAllText(openCodeConfigPath), originalOpenCodeConfig), "OpenCode rollback should restore the pre-install config");

    using var factoryDroidDiff = ToJsonDocument(adapter.Handle("/agents/factory-droid/diff", "POST"));
    var factoryDroidDiffFile = factoryDroidDiff.RootElement.GetProperty("plan").GetProperty("files")[0];
    Assert(!factoryDroidDiff.RootElement.GetProperty("status").GetProperty("configured").GetBoolean(), "Factory Droid should not treat unrelated custom models as Quotio configuration");
    Assert(factoryDroidDiffFile.GetProperty("has_changes").GetBoolean(), "Factory Droid diff preview should report the pending config change");
    Assert(!factoryDroidDiffFile.GetProperty("after").GetString()!.Contains("smoke-management-key", StringComparison.Ordinal), "Factory Droid diff preview should redact management keys");
    Assert(factoryDroidDiffFile.GetProperty("after").GetString()!.Contains("\"custom_models\"", StringComparison.Ordinal), "Factory Droid diff preview should include custom models");

    using var factoryDroidInstall = ToJsonDocument(adapter.Handle("/agents/factory-droid/install", "POST"));
    Assert(factoryDroidInstall.RootElement.GetProperty("summary").GetString()?.Contains("installed", StringComparison.OrdinalIgnoreCase) == true, "Factory Droid install should succeed");
    Assert(factoryDroidInstall.RootElement.GetProperty("status").GetProperty("configured").GetBoolean(), "Factory Droid install should mark the adapter configured");
    Assert(factoryDroidInstall.RootElement.GetProperty("status").GetProperty("rollback_available").GetBoolean(), "Factory Droid install should create a rollback backup");
    var installedFactoryDroidConfig = File.ReadAllText(factoryConfigPath);
    Assert(installedFactoryDroidConfig.Contains("\"model\": \"gpt-5-codex\"", StringComparison.Ordinal), "Factory Droid install should write the default Quotio model");
    Assert(installedFactoryDroidConfig.Contains("\"base_url\": \"http://127.0.0.1:8787/v1\"", StringComparison.Ordinal), "Factory Droid install should normalize the proxy endpoint");
    Assert(installedFactoryDroidConfig.Contains("\"api_key\": \"smoke-management-key\"", StringComparison.Ordinal), "Factory Droid install should write the configured key to disk");

    using var factoryDroidRollback = ToJsonDocument(adapter.Handle("/agents/factory-droid/rollback", "POST"));
    Assert(factoryDroidRollback.RootElement.GetProperty("summary").GetString()?.Contains("restored", StringComparison.OrdinalIgnoreCase) == true, "Factory Droid rollback should restore the latest backup");
    Assert(JsonEquivalent(File.ReadAllText(factoryConfigPath), originalFactoryConfig), "Factory Droid rollback should restore the pre-install config");

    using var claudeCodeDiff = ToJsonDocument(adapter.Handle("/agents/claude-code/diff", "POST"));
    var claudeCodeDiffFile = claudeCodeDiff.RootElement.GetProperty("plan").GetProperty("files")[0];
    Assert(!claudeCodeDiff.RootElement.GetProperty("status").GetProperty("configured").GetBoolean(), "Claude Code should not treat unrelated settings as Quotio configuration");
    Assert(claudeCodeDiffFile.GetProperty("has_changes").GetBoolean(), "Claude Code diff preview should report the pending config change");
    Assert(!claudeCodeDiffFile.GetProperty("after").GetString()!.Contains("smoke-management-key", StringComparison.Ordinal), "Claude Code diff preview should redact management keys");
    Assert(claudeCodeDiffFile.GetProperty("after").GetString()!.Contains("ANTHROPIC_BASE_URL", StringComparison.Ordinal), "Claude Code diff preview should include Anthropic env settings");

    using var claudeCodeInstall = ToJsonDocument(adapter.Handle("/agents/claude-code/install", "POST"));
    Assert(claudeCodeInstall.RootElement.GetProperty("summary").GetString()?.Contains("installed", StringComparison.OrdinalIgnoreCase) == true, "Claude Code install should succeed");
    Assert(claudeCodeInstall.RootElement.GetProperty("status").GetProperty("configured").GetBoolean(), "Claude Code install should mark the adapter configured");
    Assert(claudeCodeInstall.RootElement.GetProperty("status").GetProperty("rollback_available").GetBoolean(), "Claude Code install should create a rollback backup");
    var installedClaudeConfig = File.ReadAllText(claudeConfigPath);
    Assert(installedClaudeConfig.Contains("\"MCP_API_KEY\": \"preserve-me\"", StringComparison.Ordinal), "Claude Code install should preserve existing env keys");
    Assert(installedClaudeConfig.Contains("\"permissions\"", StringComparison.Ordinal), "Claude Code install should preserve top-level user settings");
    Assert(installedClaudeConfig.Contains("\"ANTHROPIC_BASE_URL\": \"http://127.0.0.1:8787\"", StringComparison.Ordinal), "Claude Code install should strip /v1 from the proxy endpoint");
    Assert(installedClaudeConfig.Contains("\"ANTHROPIC_AUTH_TOKEN\": \"smoke-management-key\"", StringComparison.Ordinal), "Claude Code install should write the configured key to disk");

    using var claudeCodeRollback = ToJsonDocument(adapter.Handle("/agents/claude-code/rollback", "POST"));
    Assert(claudeCodeRollback.RootElement.GetProperty("summary").GetString()?.Contains("restored", StringComparison.OrdinalIgnoreCase) == true, "Claude Code rollback should restore the latest backup");
    Assert(JsonEquivalent(File.ReadAllText(claudeConfigPath), originalClaudeConfig), "Claude Code rollback should restore the pre-install config");

    using var geminiDiff = ToJsonDocument(adapter.Handle("/agents/gemini-cli/diff", "POST"));
    var geminiDiffFile = geminiDiff.RootElement.GetProperty("plan").GetProperty("files")[0];
    Assert(!geminiDiff.RootElement.GetProperty("status").GetProperty("configured").GetBoolean(), "Gemini should not treat unrelated PowerShell profile content as Quotio configuration");
    Assert(geminiDiffFile.GetProperty("has_changes").GetBoolean(), "Gemini diff preview should report the pending profile change");
    Assert(!geminiDiffFile.GetProperty("after").GetString()!.Contains("smoke-management-key", StringComparison.Ordinal), "Gemini diff preview should redact management keys");
    Assert(geminiDiffFile.GetProperty("after").GetString()!.Contains("GOOGLE_GEMINI_BASE_URL", StringComparison.Ordinal), "Gemini diff preview should include Gemini env settings");

    using var geminiInstall = ToJsonDocument(adapter.Handle("/agents/gemini-cli/install", "POST"));
    Assert(geminiInstall.RootElement.GetProperty("summary").GetString()?.Contains("installed", StringComparison.OrdinalIgnoreCase) == true, "Gemini install should succeed");
    Assert(geminiInstall.RootElement.GetProperty("status").GetProperty("configured").GetBoolean(), "Gemini install should mark the adapter configured");
    Assert(geminiInstall.RootElement.GetProperty("status").GetProperty("rollback_available").GetBoolean(), "Gemini install should create a rollback backup");
    var installedGeminiProfile = File.ReadAllText(geminiProfilePath);
    Assert(installedGeminiProfile.Contains("Set-Alias gs git-status", StringComparison.Ordinal), "Gemini install should preserve existing PowerShell profile content");
    Assert(installedGeminiProfile.Contains("GOOGLE_GEMINI_BASE_URL", StringComparison.Ordinal), "Gemini install should write the Gemini base URL");
    Assert(installedGeminiProfile.Contains("http://127.0.0.1:8787", StringComparison.Ordinal), "Gemini install should strip /v1 from the proxy endpoint");
    Assert(installedGeminiProfile.Contains("GEMINI_API_KEY", StringComparison.Ordinal), "Gemini install should write the API key env name");
    Assert(installedGeminiProfile.Contains("smoke-management-key", StringComparison.Ordinal), "Gemini install should write the configured key to disk");

    using var geminiRollback = ToJsonDocument(adapter.Handle("/agents/gemini-cli/rollback", "POST"));
    Assert(geminiRollback.RootElement.GetProperty("summary").GetString()?.Contains("restored", StringComparison.OrdinalIgnoreCase) == true, "Gemini rollback should restore the latest backup");
    Assert(File.ReadAllText(geminiProfilePath) == originalGeminiProfile, "Gemini rollback should restore the pre-install PowerShell profile");

    using var ampDiff = ToJsonDocument(adapter.Handle("/agents/amp/diff", "POST"));
    var ampDiffFiles = ampDiff.RootElement.GetProperty("plan").GetProperty("files");
    Assert(!ampDiff.RootElement.GetProperty("status").GetProperty("configured").GetBoolean(), "Amp should not treat unrelated settings as Quotio configuration");
    Assert(ampDiffFiles.GetArrayLength() == 2, "Amp diff preview should include settings and secrets files");
    Assert(ampDiffFiles.EnumerateArray().All(file => file.GetProperty("has_changes").GetBoolean()), "Amp diff preview should report both pending file changes");
    Assert(!ampDiffFiles[1].GetProperty("after").GetString()!.Contains("smoke-management-key", StringComparison.Ordinal), "Amp secrets diff preview should redact management keys");
    Assert(ampDiffFiles[0].GetProperty("after").GetString()!.Contains("\"amp.url\": \"http://127.0.0.1:8787\"", StringComparison.Ordinal), "Amp settings diff preview should strip /v1 from the proxy endpoint");

    using var ampInstall = ToJsonDocument(adapter.Handle("/agents/amp/install", "POST"));
    Assert(ampInstall.RootElement.GetProperty("summary").GetString()?.Contains("installed", StringComparison.OrdinalIgnoreCase) == true, "Amp install should succeed");
    Assert(ampInstall.RootElement.GetProperty("status").GetProperty("configured").GetBoolean(), "Amp install should mark the adapter configured");
    Assert(ampInstall.RootElement.GetProperty("status").GetProperty("rollback_available").GetBoolean(), "Amp install should create rollback backups");
    Assert(File.ReadAllText(ampSettingsPath).Contains("\"amp.url\": \"http://127.0.0.1:8787\"", StringComparison.Ordinal), "Amp install should write settings URL");
    Assert(File.ReadAllText(ampSecretsPath).Contains("\"apiKey@http://127.0.0.1:8787\": \"smoke-management-key\"", StringComparison.Ordinal), "Amp install should write the configured key to disk");

    using var ampRollback = ToJsonDocument(adapter.Handle("/agents/amp/rollback", "POST"));
    Assert(ampRollback.RootElement.GetProperty("summary").GetString()?.Contains("restored", StringComparison.OrdinalIgnoreCase) == true, "Amp rollback should restore the latest backups");
    Assert(JsonEquivalent(File.ReadAllText(ampSettingsPath), originalAmpSettings), "Amp rollback should restore the pre-install settings");
    Assert(JsonEquivalent(File.ReadAllText(ampSecretsPath), originalAmpSecrets), "Amp rollback should restore the pre-install secrets");

    using var afterRollbackList = ToJsonDocument(adapter.Handle("/agents", "GET"));
    var afterRollbackCodex = afterRollbackList.RootElement.GetProperty("agents").EnumerateArray().First(agent => agent.GetProperty("id").GetString() == "codex");
    Assert(afterRollbackCodex.GetProperty("rollback_available").GetBoolean(), "Codex should keep rollback available after creating a pre-restore backup");
    var afterRollbackOpenCode = afterRollbackList.RootElement.GetProperty("agents").EnumerateArray().First(agent => agent.GetProperty("id").GetString() == "opencode");
    Assert(afterRollbackOpenCode.GetProperty("rollback_available").GetBoolean(), "OpenCode should keep rollback available after creating a pre-restore backup");
    var afterRollbackFactoryDroid = afterRollbackList.RootElement.GetProperty("agents").EnumerateArray().First(agent => agent.GetProperty("id").GetString() == "factory-droid");
    Assert(afterRollbackFactoryDroid.GetProperty("rollback_available").GetBoolean(), "Factory Droid should keep rollback available after creating a pre-restore backup");
    var afterRollbackClaudeCode = afterRollbackList.RootElement.GetProperty("agents").EnumerateArray().First(agent => agent.GetProperty("id").GetString() == "claude-code");
    Assert(afterRollbackClaudeCode.GetProperty("rollback_available").GetBoolean(), "Claude Code should keep rollback available after creating a pre-restore backup");
    var afterRollbackAmp = afterRollbackList.RootElement.GetProperty("agents").EnumerateArray().First(agent => agent.GetProperty("id").GetString() == "amp");
    Assert(afterRollbackAmp.GetProperty("rollback_available").GetBoolean(), "Amp should keep rollback available after creating pre-restore backups");
    var afterRollbackGemini = afterRollbackList.RootElement.GetProperty("agents").EnumerateArray().First(agent => agent.GetProperty("id").GetString() == "gemini-cli");
    Assert(afterRollbackGemini.GetProperty("rollback_available").GetBoolean(), "Gemini should keep rollback available after creating a pre-restore backup");
}

static JsonDocument ToJsonDocument(object value)
{
    return JsonDocument.Parse(JsonSerializer.Serialize(value));
}

static bool JsonEquivalent(string left, string right)
{
    using var leftDocument = JsonDocument.Parse(left);
    using var rightDocument = JsonDocument.Parse(right);
    return JsonSerializer.Serialize(leftDocument.RootElement) == JsonSerializer.Serialize(rightDocument.RootElement);
}

static void ClearEnvironment()
{
    Environment.SetEnvironmentVariable("QUOTIO_DESKTOP_UI_DEV_SERVER", null);
    Environment.SetEnvironmentVariable("QUOTIO_MANAGEMENT_BASE_URL", null);
    Environment.SetEnvironmentVariable("QUOTIO_MANAGEMENT_KEY", null);
    Environment.SetEnvironmentVariable("QUOTIO_PROXY_ENDPOINT", null);
    Environment.SetEnvironmentVariable("QUOTIO_PROXY_BINARY", null);
    Environment.SetEnvironmentVariable("QUOTIO_PROXY_ARGS", null);
    Environment.SetEnvironmentVariable("QUOTIO_WINDOWS_CRASH_REPORT_DIR", null);
    Environment.SetEnvironmentVariable("QUOTIO_WINDOWS_CRASH_UPLOAD_URL", null);
    Environment.SetEnvironmentVariable("QUOTIO_WINDOWS_UPDATE_REPOSITORY_URL", null);
    Environment.SetEnvironmentVariable("QUOTIO_WINDOWS_UPDATE_CHANNEL", null);
}

static void Assert(bool condition, string message)
{
    if (!condition)
    {
        throw new InvalidOperationException(message);
    }
}

static void AssertExactBoolDictionary(IReadOnlyDictionary<string, bool> actual, IReadOnlyDictionary<string, bool> expected, string label)
{
    var actualKeys = actual.Keys.OrderBy(key => key, StringComparer.Ordinal).ToArray();
    var expectedKeys = expected.Keys.OrderBy(key => key, StringComparer.Ordinal).ToArray();
    Assert(actualKeys.SequenceEqual(expectedKeys), $"{label} should expose exactly the approved keys");

    foreach (var (key, expectedValue) in expected)
    {
        Assert(actual[key] == expectedValue, $"{label} should expose {key}={expectedValue}");
    }
}

static string ReadHttpRequestBody(TcpListener listener)
{
    using var client = listener.AcceptTcpClient();
    using var stream = client.GetStream();
    using var reader = new StreamReader(stream, Encoding.UTF8, leaveOpen: true);
    var headers = new List<string>();
    string? line;
    while (!string.IsNullOrEmpty(line = reader.ReadLine()))
    {
        headers.Add(line);
    }

    var contentLength = headers
        .Select(header => header.Split(':', 2))
        .Where(parts => parts.Length == 2)
        .FirstOrDefault(parts => parts[0].Equals("Content-Length", StringComparison.OrdinalIgnoreCase))?[1]
        .Trim();
    var length = int.TryParse(contentLength, out var parsedLength) ? parsedLength : 0;
    var buffer = new char[length];
    var offset = 0;
    while (offset < length)
    {
        var read = reader.Read(buffer, offset, length - offset);
        if (read == 0)
        {
            break;
        }
        offset += read;
    }

    var response = Encoding.ASCII.GetBytes("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n");
    stream.Write(response);
    listener.Stop();
    return new string(buffer, 0, offset);
}

static void RunRuntimeChildServer(string host, int port, int lifetimeSeconds)
{
    WriteRuntimeChildPidFile();
    var listener = new TcpListener(IPAddress.Parse(host), port);
    listener.Start();
    Thread.Sleep(TimeSpan.FromSeconds(lifetimeSeconds));
    listener.Stop();
}

static void WriteRuntimeChildPidFile()
{
    var path = Environment.GetEnvironmentVariable("QUOTIO_RUNTIME_CHILD_PID_FILE");
    if (!string.IsNullOrWhiteSpace(path))
    {
        File.WriteAllText(path, Environment.ProcessId.ToString());
    }
}

static int WaitForPidFile(string path, int? previousPid = null)
{
    var deadline = DateTimeOffset.UtcNow + TimeSpan.FromSeconds(2);
    while (DateTimeOffset.UtcNow < deadline)
    {
        if (File.Exists(path) && int.TryParse(File.ReadAllText(path), out var pid) && pid != previousPid)
        {
            return pid;
        }

        Thread.Sleep(TimeSpan.FromMilliseconds(50));
    }

    throw new InvalidOperationException($"Runtime child PID file was not written: {path}");
}

static bool WaitForProcess(int pid, bool running)
{
    var deadline = DateTimeOffset.UtcNow + TimeSpan.FromSeconds(2);
    while (DateTimeOffset.UtcNow < deadline)
    {
        if (ProcessIsRunning(pid) == running)
        {
            return true;
        }

        Thread.Sleep(TimeSpan.FromMilliseconds(50));
    }

    return false;
}

static bool ProcessIsRunning(int pid)
{
    try
    {
        using var process = Process.GetProcessById(pid);
        return !process.HasExited;
    }
    catch (ArgumentException)
    {
        return false;
    }
    catch (InvalidOperationException)
    {
        return false;
    }
}
