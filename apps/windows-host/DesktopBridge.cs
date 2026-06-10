namespace Quotio.Windows;

using System.Diagnostics;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using Quotio.Contract;
using WinForms = System.Windows.Forms;

public sealed class DesktopBridge
{
    private const string BridgeReceiveFunction = "window.__QUOTIO_DESKTOP_BRIDGE_RECEIVE__";
    private readonly WebView2 webView;
    private readonly RuntimeProcessController runtime;
    private readonly WindowsHostConfig config;
    private readonly WindowsAgentAdapter agents;
    private readonly WindowsNativePreferencesStore preferencesStore;
    private readonly WindowsUpdateService updates;
    private readonly Func<string, string, string, bool> notify;
    private readonly Action<string> applyAppearance;
    private readonly HttpClient httpClient = new();

    public DesktopBridge(
        WebView2 webView,
        RuntimeProcessController runtime,
        WindowsHostConfig config,
        WindowsAgentAdapter agents,
        WindowsNativePreferencesStore preferencesStore,
        WindowsUpdateService updates,
        Func<string, string, string, bool> notify,
        Action<string>? applyAppearance = null
    )
    {
        this.webView = webView;
        this.runtime = runtime;
        this.config = config;
        this.agents = agents;
        this.preferencesStore = preferencesStore;
        this.updates = updates;
        this.notify = notify;
        this.applyAppearance = applyAppearance ?? (_ => { });
    }

    public string CreateBootstrapScript(DesktopBootstrap bootstrap)
    {
        var bootstrapJson = JsonSerializer.Serialize(
            bootstrap,
            JsonOptions.CamelCase
        );

        return $$"""
        (() => {
          const bootstrap = {{bootstrapJson}};
          window.__QUOTIO_DESKTOP_BOOTSTRAP__ = bootstrap;
          window.__QUOTIO_DESKTOP_BRIDGE__ = {
            request: (request) => new Promise((resolve, reject) => {
              const id = request?.id || crypto.randomUUID();
              window.__QUOTIO_BRIDGE_CALLBACKS__ = window.__QUOTIO_BRIDGE_CALLBACKS__ || {};
              window.__QUOTIO_BRIDGE_CALLBACKS__[id] = { resolve, reject };
              chrome.webview.postMessage({
                id,
                kind: 'management.request',
                path: request?.path,
                init: request?.init || {}
              });
            }),
            runtimeStatus: () => new Promise((resolve, reject) => {
              const id = crypto.randomUUID();
              window.__QUOTIO_BRIDGE_CALLBACKS__ = window.__QUOTIO_BRIDGE_CALLBACKS__ || {};
              window.__QUOTIO_BRIDGE_CALLBACKS__[id] = { resolve, reject };
              chrome.webview.postMessage({ id, kind: 'runtime.status' });
            }),
            runtimeStart: () => new Promise((resolve, reject) => {
              const id = crypto.randomUUID();
              window.__QUOTIO_BRIDGE_CALLBACKS__ = window.__QUOTIO_BRIDGE_CALLBACKS__ || {};
              window.__QUOTIO_BRIDGE_CALLBACKS__[id] = { resolve, reject };
              chrome.webview.postMessage({ id, kind: 'runtime.start' });
            }),
            runtimeStop: () => new Promise((resolve, reject) => {
              const id = crypto.randomUUID();
              window.__QUOTIO_BRIDGE_CALLBACKS__ = window.__QUOTIO_BRIDGE_CALLBACKS__ || {};
              window.__QUOTIO_BRIDGE_CALLBACKS__[id] = { resolve, reject };
              chrome.webview.postMessage({ id, kind: 'runtime.stop' });
            }),
            runtimeRestart: () => new Promise((resolve, reject) => {
              const id = crypto.randomUUID();
              window.__QUOTIO_BRIDGE_CALLBACKS__ = window.__QUOTIO_BRIDGE_CALLBACKS__ || {};
              window.__QUOTIO_BRIDGE_CALLBACKS__[id] = { resolve, reject };
              chrome.webview.postMessage({ id, kind: 'runtime.restart' });
            }),
            confirm: (request) => new Promise((resolve, reject) => {
              const id = crypto.randomUUID();
              window.__QUOTIO_BRIDGE_CALLBACKS__ = window.__QUOTIO_BRIDGE_CALLBACKS__ || {};
              window.__QUOTIO_BRIDGE_CALLBACKS__[id] = { resolve, reject };
              chrome.webview.postMessage({
                id,
                kind: 'native.confirm',
                title: request?.title,
                message: request?.message,
                confirmLabel: request?.confirmLabel,
                cancelLabel: request?.cancelLabel,
                destructive: request?.destructive === true
              });
            }),
            notify: (request) => new Promise((resolve, reject) => {
              const id = crypto.randomUUID();
              window.__QUOTIO_BRIDGE_CALLBACKS__ = window.__QUOTIO_BRIDGE_CALLBACKS__ || {};
              window.__QUOTIO_BRIDGE_CALLBACKS__[id] = { resolve, reject };
              chrome.webview.postMessage({
                id,
                kind: 'native.notify',
                title: request?.title,
                message: request?.message,
                tone: request?.tone
              });
            }),
            openExternal: (url) => new Promise((resolve, reject) => {
              const id = crypto.randomUUID();
              window.__QUOTIO_BRIDGE_CALLBACKS__ = window.__QUOTIO_BRIDGE_CALLBACKS__ || {};
              window.__QUOTIO_BRIDGE_CALLBACKS__[id] = { resolve, reject };
              chrome.webview.postMessage({ id, kind: 'native.openExternal', url });
            }),
            openTextFile: (request) => new Promise((resolve, reject) => {
              const id = crypto.randomUUID();
              window.__QUOTIO_BRIDGE_CALLBACKS__ = window.__QUOTIO_BRIDGE_CALLBACKS__ || {};
              window.__QUOTIO_BRIDGE_CALLBACKS__[id] = { resolve, reject };
              chrome.webview.postMessage({
                id,
                kind: 'native.openTextFile',
                title: request?.title,
                allowedExtensions: request?.allowedExtensions || []
              });
            }),
            credentialRead: (request) => new Promise((resolve, reject) => {
              const id = crypto.randomUUID();
              window.__QUOTIO_BRIDGE_CALLBACKS__ = window.__QUOTIO_BRIDGE_CALLBACKS__ || {};
              window.__QUOTIO_BRIDGE_CALLBACKS__[id] = { resolve, reject };
              chrome.webview.postMessage({
                id,
                kind: 'native.credentialRead',
                targetName: request?.targetName
              });
            }),
            credentialWrite: (request) => new Promise((resolve, reject) => {
              const id = crypto.randomUUID();
              window.__QUOTIO_BRIDGE_CALLBACKS__ = window.__QUOTIO_BRIDGE_CALLBACKS__ || {};
              window.__QUOTIO_BRIDGE_CALLBACKS__[id] = { resolve, reject };
              chrome.webview.postMessage({
                id,
                kind: 'native.credentialWrite',
                targetName: request?.targetName,
                value: request?.value
              });
            }),
            credentialDelete: (request) => new Promise((resolve, reject) => {
              const id = crypto.randomUUID();
              window.__QUOTIO_BRIDGE_CALLBACKS__ = window.__QUOTIO_BRIDGE_CALLBACKS__ || {};
              window.__QUOTIO_BRIDGE_CALLBACKS__[id] = { resolve, reject };
              chrome.webview.postMessage({
                id,
                kind: 'native.credentialDelete',
                targetName: request?.targetName
              });
            }),
            preferencesRead: () => new Promise((resolve, reject) => {
              const id = crypto.randomUUID();
              window.__QUOTIO_BRIDGE_CALLBACKS__ = window.__QUOTIO_BRIDGE_CALLBACKS__ || {};
              window.__QUOTIO_BRIDGE_CALLBACKS__[id] = { resolve, reject };
              chrome.webview.postMessage({ id, kind: 'native.preferencesRead' });
            }),
            preferencesWrite: (request) => new Promise((resolve, reject) => {
              const id = crypto.randomUUID();
              window.__QUOTIO_BRIDGE_CALLBACKS__ = window.__QUOTIO_BRIDGE_CALLBACKS__ || {};
              window.__QUOTIO_BRIDGE_CALLBACKS__[id] = { resolve, reject };
              chrome.webview.postMessage({
                id,
                kind: 'native.preferencesWrite',
                preferences: request?.preferences || {}
              });
            }),
            updatesCheck: () => new Promise((resolve, reject) => {
              const id = crypto.randomUUID();
              window.__QUOTIO_BRIDGE_CALLBACKS__ = window.__QUOTIO_BRIDGE_CALLBACKS__ || {};
              window.__QUOTIO_BRIDGE_CALLBACKS__[id] = { resolve, reject };
              chrome.webview.postMessage({ id, kind: 'native.updatesCheck' });
            })
          };
          window.__QUOTIO_DESKTOP_BRIDGE_RECEIVE__ = (message) => {
            const callbacks = window.__QUOTIO_BRIDGE_CALLBACKS__ || {};
            const callback = callbacks[message.id];
            if (!callback) return;
            delete callbacks[message.id];
            if (message.ok) {
              callback.resolve(message.value);
            } else {
              callback.reject(new Error(message.error || 'Desktop bridge request failed'));
            }
          };
        })();
        """;
    }

    public async void OnWebMessageReceived(
        CoreWebView2 sender,
        CoreWebView2WebMessageReceivedEventArgs args
    )
    {
        var started = Stopwatch.StartNew();
        string requestId = "";
        string requestKind = "";

        try
        {
            using var document = JsonDocument.Parse(args.WebMessageAsJson);
            var root = document.RootElement;
            requestId = root.GetProperty("id").GetString() ?? "";
            requestKind = root.GetProperty("kind").GetString() ?? "";

            object? value = requestKind switch
            {
                "runtime.status" => runtime.Status(),
                "runtime.start" => runtime.Start(),
                "runtime.stop" => runtime.Stop(),
                "runtime.restart" => runtime.Restart(),
                "management.request" => await HandleManagementRequestAsync(root),
                "native.confirm" => await HandleNativeConfirmAsync(root),
                "native.notify" => HandleNativeNotify(root),
                "native.openExternal" => HandleNativeOpenExternal(root),
                "native.openTextFile" => HandleNativeOpenTextFile(root),
                "native.credentialRead" => HandleNativeCredentialRead(root),
                "native.credentialWrite" => HandleNativeCredentialWrite(root),
                "native.credentialDelete" => HandleNativeCredentialDelete(root),
                "native.preferencesRead" => HandleNativePreferencesRead(),
                "native.preferencesWrite" => HandleNativePreferencesWrite(root),
                "native.updatesCheck" => await HandleNativeUpdatesCheckAsync(),
                _ => throw new InvalidOperationException("Unsupported bridge request")
            };

            DiagnosticLog.Info($"Bridge {requestId} {requestKind} ok {started.ElapsedMilliseconds}ms");
            await SendResponseAsync(requestId, ok: true, value, error: null);
        }
        catch (Exception error)
        {
            DiagnosticLog.Error($"Bridge {requestId} {requestKind} failed {started.ElapsedMilliseconds}ms", error);
            await SendResponseAsync(requestId, ok: false, value: null, error: error.Message);
        }
    }

    private async Task<object> HandleManagementRequestAsync(JsonElement root)
    {
        var path = root.GetProperty("path").GetString() ?? "";
        if (!path.StartsWith('/') || path.StartsWith("//", StringComparison.Ordinal))
        {
            throw new InvalidOperationException("Invalid management path");
        }

        var init = root.TryGetProperty("init", out var initElement) ? initElement : default;
        var method = init.ValueKind == JsonValueKind.Object
            && init.TryGetProperty("method", out var methodElement)
            ? methodElement.GetString() ?? "GET"
            : "GET";
        var body = init.ValueKind == JsonValueKind.Object
            && init.TryGetProperty("body", out var bodyElement)
            ? bodyElement.GetString()
            : null;

        if (path == "/agents" || path.StartsWith("/agents/", StringComparison.Ordinal))
        {
            return agents.Handle(path, method);
        }

        var preferences = preferencesStore.Load();
        var baseUrl = !string.IsNullOrWhiteSpace(config.ManagementBaseUrl)
            ? config.ManagementBaseUrl
            : config.LocalProxyAvailable && preferences.OperatingMode == "local"
                ? config.ProxyEndpoint
                : null;
        var managementKey = config.ManagementKey;
        if (string.IsNullOrWhiteSpace(baseUrl))
        {
            throw new InvalidOperationException("Windows management bridge is not configured");
        }

        using var request = new HttpRequestMessage(
            new HttpMethod(method.ToUpperInvariant()),
            new Uri(new Uri($"{NormalizeManagementBaseUrl(baseUrl)}/"), path.TrimStart('/'))
        );
        if (!string.IsNullOrWhiteSpace(managementKey))
        {
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", managementKey);
        }
        request.Headers.ConnectionClose = true;
        if (!string.IsNullOrEmpty(body))
        {
            request.Content = new StringContent(body, Encoding.UTF8, "application/json");
        }

        using var response = await httpClient.SendAsync(request);
        var responseBody = await response.Content.ReadAsStringAsync();
        if (!response.IsSuccessStatusCode)
        {
            throw new InvalidOperationException($"Management request failed with {(int)response.StatusCode}");
        }

        if (string.IsNullOrWhiteSpace(responseBody))
        {
            return new ManagementResponse { Status = (int)response.StatusCode, Body = null };
        }

        return JsonSerializer.Deserialize<JsonElement>(responseBody);
    }

    private async Task<bool> HandleNativeConfirmAsync(JsonElement root)
    {
        static string ReadString(JsonElement element, string propertyName, string fallback)
        {
            return element.TryGetProperty(propertyName, out var property)
                && property.ValueKind == JsonValueKind.String
                ? property.GetString() ?? fallback
                : fallback;
        }

        var dialog = new ContentDialog
        {
            Title = ReadString(root, "title", "Quotio"),
            Content = ReadString(root, "message", ""),
            PrimaryButtonText = ReadString(root, "confirmLabel", "OK"),
            CloseButtonText = ReadString(root, "cancelLabel", "Cancel"),
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = webView.XamlRoot
        };

        var result = await dialog.ShowAsync();
        return result == ContentDialogResult.Primary;
    }

    private bool HandleNativeNotify(JsonElement root)
    {
        return notify(
            ReadString(root, "title", "Quotio"),
            ReadString(root, "message", ""),
            ReadString(root, "tone", "success")
        );
    }

    private static bool HandleNativeOpenExternal(JsonElement root)
    {
        var rawUrl = root.TryGetProperty("url", out var urlElement)
            && urlElement.ValueKind == JsonValueKind.String
            ? urlElement.GetString()
            : null;
        if (!Uri.TryCreate(rawUrl, UriKind.Absolute, out var url)
            || !IsAllowedExternalUri(url))
        {
            throw new InvalidOperationException("Invalid external URL");
        }

        Process.Start(new ProcessStartInfo(url.ToString()) { UseShellExecute = true });
        return true;
    }

    private static bool IsAllowedExternalUri(Uri url)
    {
        return string.Equals(url.Scheme, Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase)
            || string.Equals(url.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase)
            || string.Equals(url.ToString(), "ms-settings:startupapps", StringComparison.OrdinalIgnoreCase);
    }

    private static string? HandleNativeOpenTextFile(JsonElement root)
    {
        var dialog = new WinForms.OpenFileDialog
        {
            Title = ReadString(root, "title", "Open File"),
            Filter = BuildOpenTextFileFilter(root),
            Multiselect = false,
            CheckFileExists = true
        };

        return dialog.ShowDialog() == WinForms.DialogResult.OK
            ? File.ReadAllText(dialog.FileName, Encoding.UTF8)
            : null;
    }

    private static NativeCredential HandleNativeCredentialRead(JsonElement root)
    {
        var targetName = ReadRequiredCredentialTargetName(root);
        var value = WindowsCredentialStore.TryReadGenericCredential(targetName);
        return new NativeCredential
        {
            TargetName = targetName,
            Exists = value is not null,
            Value = value
        };
    }

    private static bool HandleNativeCredentialWrite(JsonElement root)
    {
        var targetName = ReadRequiredCredentialTargetName(root);
        var value = ReadString(root, "value", "");
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new InvalidOperationException("Credential value is required");
        }

        WindowsCredentialStore.WriteGenericCredential(targetName, value);
        return true;
    }

    private static bool HandleNativeCredentialDelete(JsonElement root)
    {
        WindowsCredentialStore.DeleteGenericCredential(ReadRequiredCredentialTargetName(root));
        return true;
    }

    private object HandleNativePreferencesRead()
    {
        return BuildNativePreferencesPayload();
    }

    private object HandleNativePreferencesWrite(JsonElement root)
    {
        var preferences = root.TryGetProperty("preferences", out var preferencesElement)
            && preferencesElement.ValueKind == JsonValueKind.Object
            ? preferencesElement
            : throw new InvalidOperationException("Preferences payload is required");

        var updatedPreferences = preferencesStore.Update(preferences, config);
        applyAppearance(updatedPreferences.Appearance);
        return BuildNativePreferencesPayload();
    }

    private async Task<object> HandleNativeUpdatesCheckAsync()
    {
        await updates.CheckForUpdatesAsync();
        return BuildNativePreferencesPayload();
    }

    private object BuildNativePreferencesPayload()
    {
        var preferences = preferencesStore.Load();
        var status = runtime.Status();
        var updateSnapshot = updates.Snapshot();
        var localProxyAvailable = config.LocalProxyAvailable;
        var operatingMode = localProxyAvailable && preferences.OperatingMode == "local" ? "local" : "remote";
        var proxyEndpoint = config.ProxyEndpoint;
        var proxyPort = Uri.TryCreate(proxyEndpoint, UriKind.Absolute, out var proxyUri)
            ? proxyUri.Port
            : 8386;

        return new Dictionary<string, object?>
        {
            ["operatingMode"] = operatingMode,
            ["remoteConfigured"] = !string.IsNullOrWhiteSpace(config.ManagementBaseUrl),
            ["language"] = preferences.Language,
            ["appearance"] = preferences.Appearance,
            ["launchAtLogin"] = WindowsStartupService.IsEnabled(),
            ["launchAtLoginCanOpenSystemSettings"] = true,
            ["proxyPort"] = proxyPort,
            ["proxyEndpoint"] = status.Endpoint ?? proxyEndpoint,
            ["proxyRunning"] = status.State == "managed",
            ["proxyServerKind"] = "cpa-plusplus",
            ["proxyServerVersion"] = null,
            ["proxyInstallStatus"] = string.IsNullOrWhiteSpace(config.ProxyBinary) ? "not-installed" : "dev-override",
            ["proxyActiveBinaryPath"] = config.ProxyBinary ?? "",
            ["proxyConfigPath"] = "",
            ["allowNetworkAccess"] = false,
            ["autoStartTunnel"] = false,
            ["autoRestartTunnel"] = false,
            ["tunnelInstalled"] = false,
            ["authDir"] = "",
            ["defaultAuthDir"] = "",
            ["notificationsEnabled"] = preferences.NotificationsEnabled,
            ["notifyOnQuotaLow"] = preferences.NotifyOnQuotaLow,
            ["notifyOnCooling"] = preferences.NotifyOnCooling,
            ["notifyOnProxyCrash"] = preferences.NotifyOnProxyCrash,
            ["quotaAlertThreshold"] = preferences.QuotaAlertThreshold,
            ["quotaDisplayMode"] = preferences.QuotaDisplayMode,
            ["quotaDisplayStyle"] = preferences.QuotaDisplayStyle,
            ["resetTimeDisplayMode"] = preferences.ResetTimeDisplayMode,
            ["refreshCadence"] = preferences.RefreshCadence,
            ["showInDock"] = true,
            ["showMenuBarIcon"] = true,
            ["showQuotaInMenuBar"] = false,
            ["menuBarMaxItems"] = 3,
            ["menuBarColorMode"] = "colored",
            ["hideSensitiveInfo"] = preferences.HideSensitiveInfo,
            ["totalUsageMode"] = preferences.TotalUsageMode,
            ["modelAggregationMode"] = preferences.ModelAggregationMode,
            ["updatesSupported"] = updateSnapshot.UpdatesSupported,
            ["autoCheckUpdates"] = updateSnapshot.AutoCheckUpdates,
            ["updateChannel"] = updateSnapshot.UpdateChannel,
            ["updateChannelLocked"] = updateSnapshot.UpdateChannelLocked,
            ["canCheckForUpdates"] = updateSnapshot.CanCheckForUpdates,
            ["isCheckingForUpdates"] = updateSnapshot.IsCheckingForUpdates,
            ["lastUpdateCheckAt"] = updateSnapshot.LastUpdateCheckAt
        };
    }

    private static string ReadRequiredCredentialTargetName(JsonElement root)
    {
        var targetName = ReadString(root, "targetName", "").Trim();
        if (string.IsNullOrEmpty(targetName) || !targetName.StartsWith("Quotio/", StringComparison.Ordinal))
        {
            throw new InvalidOperationException("Invalid credential target");
        }

        return targetName;
    }

    private static string ReadString(JsonElement element, string propertyName, string fallback)
    {
        return element.TryGetProperty(propertyName, out var property)
            && property.ValueKind == JsonValueKind.String
            ? property.GetString() ?? fallback
            : fallback;
    }

    private static string BuildOpenTextFileFilter(JsonElement root)
    {
        if (!root.TryGetProperty("allowedExtensions", out var extensions)
            || extensions.ValueKind != JsonValueKind.Array)
        {
            return "Text files (*.json;*.txt)|*.json;*.txt|All files (*.*)|*.*";
        }

        var patterns = extensions.EnumerateArray()
            .Where(extension => extension.ValueKind == JsonValueKind.String)
            .Select(extension => extension.GetString()?.Trim().TrimStart('.'))
            .Where(extension => !string.IsNullOrWhiteSpace(extension))
            .Select(extension => $"*.{extension}")
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();

        return patterns.Length == 0
            ? "Text files (*.json;*.txt)|*.json;*.txt|All files (*.*)|*.*"
            : $"Supported files ({string.Join(';', patterns)})|{string.Join(';', patterns)}|All files (*.*)|*.*";
    }

    private Task SendResponseAsync(string id, bool ok, object? value, string? error)
    {
        var payload = JsonSerializer.Serialize(
            new BridgeResponse(id, ok, value, error),
            JsonOptions.CamelCase
        );
        return webView.CoreWebView2.ExecuteScriptAsync($"{BridgeReceiveFunction}({payload});").AsTask();
    }

    private static string NormalizeManagementBaseUrl(string rawUrl)
    {
        var url = rawUrl.Trim().TrimEnd('/');
        if (url.EndsWith("/v0/management", StringComparison.OrdinalIgnoreCase))
        {
            return url;
        }
        if (url.EndsWith("/v0", StringComparison.OrdinalIgnoreCase))
        {
            return $"{url}/management";
        }
        return $"{url}/v0/management";
    }
}

public sealed record BridgeResponse(string Id, bool Ok, object? Value, string? Error);
