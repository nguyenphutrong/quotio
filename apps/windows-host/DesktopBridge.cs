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
    private readonly HttpClient httpClient = new();

    public DesktopBridge(WebView2 webView, RuntimeProcessController runtime, WindowsHostConfig config, WindowsAgentAdapter agents)
    {
        this.webView = webView;
        this.runtime = runtime;
        this.config = config;
        this.agents = agents;
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
                "management.request" => await HandleManagementRequestAsync(root),
                "native.confirm" => await HandleNativeConfirmAsync(root),
                "native.openExternal" => HandleNativeOpenExternal(root),
                "native.openTextFile" => HandleNativeOpenTextFile(root),
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

        var baseUrl = config.ManagementBaseUrl;
        var managementKey = config.ManagementKey;
        if (string.IsNullOrEmpty(baseUrl) || string.IsNullOrEmpty(managementKey))
        {
            throw new InvalidOperationException("Windows management bridge is not configured");
        }

        using var request = new HttpRequestMessage(
            new HttpMethod(method.ToUpperInvariant()),
            new Uri(new Uri($"{NormalizeManagementBaseUrl(baseUrl)}/"), path.TrimStart('/'))
        );
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", managementKey);
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

    private static bool HandleNativeOpenExternal(JsonElement root)
    {
        var rawUrl = root.TryGetProperty("url", out var urlElement)
            && urlElement.ValueKind == JsonValueKind.String
            ? urlElement.GetString()
            : null;
        if (!Uri.TryCreate(rawUrl, UriKind.Absolute, out var url)
            || (url.Scheme != Uri.UriSchemeHttp && url.Scheme != Uri.UriSchemeHttps))
        {
            throw new InvalidOperationException("Invalid external URL");
        }

        Process.Start(new ProcessStartInfo(url.ToString()) { UseShellExecute = true });
        return true;
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
