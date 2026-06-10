namespace Quotio.Windows;

using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

public sealed class WindowsFactoryDroidConfigPatcher
{
    private const string DefaultModel = "gpt-5-codex";
    private readonly string homeDirectory;

    public WindowsFactoryDroidConfigPatcher()
        : this(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile))
    {
    }

    public WindowsFactoryDroidConfigPatcher(string homeDirectory)
    {
        this.homeDirectory = homeDirectory;
    }

    public string ConfigPath => Path.Combine(homeDirectory, ".factory", "config.json");

    public bool IsConfigured()
    {
        if (!File.Exists(ConfigPath))
        {
            return false;
        }

        try
        {
            var root = JsonNode.Parse(File.ReadAllText(ConfigPath, Encoding.UTF8)) as JsonObject;
            return root?["custom_models"] is JsonArray customModels
                && customModels.Any(model => model?["model"]?.GetValue<string>() == DefaultModel);
        }
        catch (JsonException)
        {
            return false;
        }
    }

    public string? LatestBackupPath()
    {
        var directory = Path.GetDirectoryName(ConfigPath);
        var fileName = Path.GetFileName(ConfigPath);
        if (string.IsNullOrEmpty(directory) || !Directory.Exists(directory))
        {
            return null;
        }

        return Directory
            .EnumerateFiles(directory, $"{fileName}.backup.*")
            .Select(path => new FileInfo(path))
            .OrderByDescending(file => file.LastWriteTimeUtc)
            .ThenByDescending(file => file.Name, StringComparer.Ordinal)
            .FirstOrDefault()
            ?.FullName;
    }

    public FactoryDroidPlan BuildPlan(string proxyEndpoint, string apiKey)
    {
        var before = File.Exists(ConfigPath)
            ? File.ReadAllText(ConfigPath, Encoding.UTF8)
            : "";
        var after = BuildConfigContent(NormalizeProxyBaseUrl(proxyEndpoint), apiKey);

        return new FactoryDroidPlan(
            ConfigPath,
            File.Exists(ConfigPath),
            before != after,
            RedactSecrets(before),
            RedactSecrets(after)
        );
    }

    public FactoryDroidInstallResult Install(string proxyEndpoint, string apiKey)
    {
        var before = File.Exists(ConfigPath)
            ? File.ReadAllText(ConfigPath, Encoding.UTF8)
            : "";
        var after = BuildConfigContent(NormalizeProxyBaseUrl(proxyEndpoint), apiKey);

        Directory.CreateDirectory(Path.GetDirectoryName(ConfigPath)!);

        var backupPath = BackupConfigIfNeeded();
        File.WriteAllText(ConfigPath, after, Encoding.UTF8);

        return new FactoryDroidInstallResult(
            new FactoryDroidPlan(
                ConfigPath,
                before.Length > 0,
                before != after,
                RedactSecrets(before),
                RedactSecrets(after)
            ),
            backupPath
        );
    }

    public FactoryDroidRollbackResult Rollback()
    {
        var restorePath = LatestBackupPath();
        if (restorePath is null)
        {
            return new FactoryDroidRollbackResult(null, null);
        }

        Directory.CreateDirectory(Path.GetDirectoryName(ConfigPath)!);
        var preRestoreBackupPath = BackupConfigIfNeeded();
        File.Copy(restorePath, ConfigPath, overwrite: true);

        return new FactoryDroidRollbackResult(restorePath, preRestoreBackupPath);
    }

    private string? BackupConfigIfNeeded()
    {
        if (!File.Exists(ConfigPath))
        {
            return null;
        }

        var baseBackupPath = $"{ConfigPath}.backup.{DateTimeOffset.UtcNow.ToUnixTimeSeconds()}";
        var backupPath = baseBackupPath;
        var suffix = 1;
        while (File.Exists(backupPath))
        {
            backupPath = $"{baseBackupPath}.{suffix}";
            suffix += 1;
        }

        File.Copy(ConfigPath, backupPath);
        return backupPath;
    }

    private static string BuildConfigContent(string proxyUrl, string apiKey)
    {
        var root = new JsonObject
        {
            ["custom_models"] = new JsonArray
            {
                new JsonObject
                {
                    ["model"] = DefaultModel,
                    ["model_display_name"] = DefaultModel,
                    ["base_url"] = proxyUrl,
                    ["api_key"] = apiKey,
                    ["provider"] = "openai"
                }
            }
        };

        return root.ToJsonString(new JsonSerializerOptions
        {
            WriteIndented = true
        }) + "\n";
    }

    private static string NormalizeProxyBaseUrl(string endpoint)
    {
        var trimmed = endpoint.Trim().TrimEnd('/');
        return trimmed.EndsWith("/v1", StringComparison.OrdinalIgnoreCase)
            ? trimmed
            : $"{trimmed}/v1";
    }

    private static string RedactSecrets(string content)
    {
        if (string.IsNullOrWhiteSpace(content))
        {
            return content;
        }

        try
        {
            var root = JsonNode.Parse(content);
            RedactApiKeys(root);
            return root?.ToJsonString(new JsonSerializerOptions { WriteIndented = true }) ?? content;
        }
        catch (JsonException)
        {
            return content;
        }
    }

    private static void RedactApiKeys(JsonNode? node)
    {
        if (node is JsonObject obj)
        {
            foreach (var key in obj.Select(pair => pair.Key).ToArray())
            {
                if (key.Equals("apiKey", StringComparison.OrdinalIgnoreCase)
                    || key.Equals("api_key", StringComparison.OrdinalIgnoreCase))
                {
                    obj[key] = "[redacted]";
                }
                else
                {
                    RedactApiKeys(obj[key]);
                }
            }
        }
        else if (node is JsonArray array)
        {
            foreach (var item in array)
            {
                RedactApiKeys(item);
            }
        }
    }
}

public sealed record FactoryDroidPlan(
    string TargetPath,
    bool Existed,
    bool HasChanges,
    string Before,
    string After
);

public sealed record FactoryDroidInstallResult(
    FactoryDroidPlan Plan,
    string? BackupPath
);

public sealed record FactoryDroidRollbackResult(
    string? RestoredBackupPath,
    string? PreRestoreBackupPath
);
