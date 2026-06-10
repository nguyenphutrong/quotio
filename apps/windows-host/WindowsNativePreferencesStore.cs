namespace Quotio.Windows;

using System.Text.Json;
using System.Text.Json.Serialization;

public sealed class WindowsNativePreferencesStore
{
    private const string ProxyEndpointTargetName = "Quotio/ProxyEndpoint";
    private readonly string filePath;

    public WindowsNativePreferencesStore()
        : this(DefaultFilePath())
    {
    }

    public WindowsNativePreferencesStore(string filePath)
    {
        this.filePath = filePath;
    }

    public WindowsNativePreferencesState Load()
    {
        try
        {
            if (!File.Exists(filePath))
            {
                return new WindowsNativePreferencesState();
            }

            var state = JsonSerializer.Deserialize<WindowsNativePreferencesState>(
                File.ReadAllText(filePath),
                JsonOptions.CamelCase
            );
            return state ?? new WindowsNativePreferencesState();
        }
        catch (Exception error)
        {
            DiagnosticLog.Error("Failed to read Windows native preferences", error);
            return new WindowsNativePreferencesState();
        }
    }

    public WindowsNativePreferencesState Update(JsonElement preferences, WindowsHostConfig config)
    {
        var state = Load();

        if (TryReadString(preferences, "operatingMode", out var operatingMode)
            && (operatingMode == "local" || operatingMode == "remote"))
        {
            state.OperatingMode = operatingMode;
        }

        if (TryReadString(preferences, "language", out var language)
            && (language == "en" || language == "vi" || language == "zh-Hans"))
        {
            state.Language = language;
        }

        if (TryReadString(preferences, "appearance", out var appearance)
            && (appearance == "system" || appearance == "light" || appearance == "dark"))
        {
            state.Appearance = appearance;
        }

        if (TryReadBool(preferences, "hideSensitiveInfo", out var hideSensitiveInfo))
        {
            state.HideSensitiveInfo = hideSensitiveInfo;
        }

        if (TryReadString(preferences, "totalUsageMode", out var totalUsageMode)
            && (totalUsageMode == "sessionOnly" || totalUsageMode == "combined"))
        {
            state.TotalUsageMode = totalUsageMode;
        }

        if (TryReadString(preferences, "modelAggregationMode", out var modelAggregationMode)
            && (modelAggregationMode == "lowest" || modelAggregationMode == "average"))
        {
            state.ModelAggregationMode = modelAggregationMode;
        }

        if (TryReadBool(preferences, "autoCheckUpdates", out var autoCheckUpdates))
        {
            state.AutoCheckUpdates = autoCheckUpdates;
        }

        if (TryReadString(preferences, "updateChannel", out var updateChannel)
            && (updateChannel == "stable" || updateChannel == "beta"))
        {
            state.UpdateChannel = updateChannel;
        }

        if (TryReadInt(preferences, "proxyPort", out var proxyPort))
        {
            if (proxyPort is < 1 or > 65535)
            {
                throw new InvalidOperationException("Proxy port must be between 1 and 65535");
            }

            if (OperatingSystem.IsWindows())
            {
                WindowsCredentialStore.WriteGenericCredential(
                    ProxyEndpointTargetName,
                    ReplaceProxyPort(config.ProxyEndpoint, proxyPort)
                );
            }
        }

        Save(state);
        return state;
    }

    public void Save(WindowsNativePreferencesState state)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(filePath)!);
        File.WriteAllText(filePath, JsonSerializer.Serialize(state, JsonOptions.IndentedCamelCase));
    }

    private static string ReplaceProxyPort(string endpoint, int port)
    {
        if (!Uri.TryCreate(endpoint, UriKind.Absolute, out var uri))
        {
            return $"http://127.0.0.1:{port}";
        }

        var builder = new UriBuilder(uri)
        {
            Port = port
        };
        return builder.Uri.ToString().TrimEnd('/');
    }

    private static bool TryReadString(JsonElement element, string propertyName, out string value)
    {
        if (element.TryGetProperty(propertyName, out var property)
            && property.ValueKind == JsonValueKind.String)
        {
            value = property.GetString() ?? "";
            return true;
        }

        value = "";
        return false;
    }

    private static bool TryReadBool(JsonElement element, string propertyName, out bool value)
    {
        if (element.TryGetProperty(propertyName, out var property)
            && (property.ValueKind == JsonValueKind.True || property.ValueKind == JsonValueKind.False))
        {
            value = property.GetBoolean();
            return true;
        }

        value = false;
        return false;
    }

    private static bool TryReadInt(JsonElement element, string propertyName, out int value)
    {
        if (element.TryGetProperty(propertyName, out var property))
        {
            if (property.ValueKind == JsonValueKind.Number && property.TryGetInt32(out value))
            {
                return true;
            }
            if (property.ValueKind == JsonValueKind.String
                && int.TryParse(property.GetString(), out value))
            {
                return true;
            }
        }

        value = 0;
        return false;
    }

    private static string DefaultFilePath()
    {
        var root = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrWhiteSpace(root))
        {
            root = Path.GetTempPath();
        }
        return Path.Combine(root, "Quotio", "windows-preferences.json");
    }
}

public sealed record WindowsNativePreferencesState
{
    public string OperatingMode { get; set; } = "local";
    public string Language { get; set; } = "en";
    public string Appearance { get; set; } = "system";
    public bool HideSensitiveInfo { get; set; }
    public string TotalUsageMode { get; set; } = "sessionOnly";
    public string ModelAggregationMode { get; set; } = "lowest";
    public bool AutoCheckUpdates { get; set; } = true;
    public string UpdateChannel { get; set; } = "stable";
}

public static partial class JsonOptions
{
    public static JsonSerializerOptions IndentedCamelCase { get; } = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };
}
