namespace Quotio.Windows;

using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

public sealed class WindowsOpenCodeConfigPatcher
{
    private const string DefaultModel = "gpt-5-codex";
    private readonly string localAppDataDirectory;

    public WindowsOpenCodeConfigPatcher()
        : this(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData))
    {
    }

    public WindowsOpenCodeConfigPatcher(string localAppDataDirectory)
    {
        this.localAppDataDirectory = localAppDataDirectory;
    }

    public string ConfigPath => Path.Combine(localAppDataDirectory, "opencode", "opencode.json");

    public bool IsConfigured()
    {
        if (!File.Exists(ConfigPath))
        {
            return false;
        }

        try
        {
            var root = JsonNode.Parse(File.ReadAllText(ConfigPath, Encoding.UTF8)) as JsonObject;
            return root?["provider"]?["quotio"] is not null;
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

    public OpenCodePlan BuildPlan(string proxyEndpoint, string apiKey)
    {
        var before = File.Exists(ConfigPath)
            ? File.ReadAllText(ConfigPath, Encoding.UTF8)
            : "";
        var after = BuildConfigContent(before, NormalizeProxyBaseUrl(proxyEndpoint), apiKey);

        return new OpenCodePlan(
            ConfigPath,
            File.Exists(ConfigPath),
            before != after,
            RedactSecrets(before),
            RedactSecrets(after)
        );
    }

    public OpenCodeInstallResult Install(string proxyEndpoint, string apiKey)
    {
        var before = File.Exists(ConfigPath)
            ? File.ReadAllText(ConfigPath, Encoding.UTF8)
            : "";
        var after = BuildConfigContent(before, NormalizeProxyBaseUrl(proxyEndpoint), apiKey);

        Directory.CreateDirectory(Path.GetDirectoryName(ConfigPath)!);

        var backupPath = BackupConfigIfNeeded();
        File.WriteAllText(ConfigPath, after, Encoding.UTF8);

        return new OpenCodeInstallResult(
            new OpenCodePlan(
                ConfigPath,
                before.Length > 0,
                before != after,
                RedactSecrets(before),
                RedactSecrets(after)
            ),
            backupPath
        );
    }

    public OpenCodeRollbackResult Rollback()
    {
        var restorePath = LatestBackupPath();
        if (restorePath is null)
        {
            return new OpenCodeRollbackResult(null, null);
        }

        Directory.CreateDirectory(Path.GetDirectoryName(ConfigPath)!);
        var preRestoreBackupPath = BackupConfigIfNeeded();
        File.Copy(restorePath, ConfigPath, overwrite: true);

        return new OpenCodeRollbackResult(restorePath, preRestoreBackupPath);
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

    private static string BuildConfigContent(string existingContent, string proxyUrl, string apiKey)
    {
        var root = ParseObjectOrEmpty(existingContent);
        if (root["$schema"] is null)
        {
            root["$schema"] = "https://opencode.ai/config.json";
        }

        var providers = root["provider"] as JsonObject;
        if (providers is null)
        {
            providers = [];
            root["provider"] = providers;
        }

        providers["quotio"] = BuildQuotioProvider(proxyUrl, apiKey);

        return root.ToJsonString(new JsonSerializerOptions
        {
            WriteIndented = true
        }) + "\n";
    }

    private static JsonObject ParseObjectOrEmpty(string content)
    {
        if (string.IsNullOrWhiteSpace(content))
        {
            return [];
        }

        try
        {
            return JsonNode.Parse(content) as JsonObject ?? [];
        }
        catch (JsonException)
        {
            return [];
        }
    }

    private static JsonObject BuildQuotioProvider(string proxyUrl, string apiKey)
    {
        return new JsonObject
        {
            ["models"] = new JsonObject
            {
                [DefaultModel] = new JsonObject
                {
                    ["name"] = "Gpt 5 Codex",
                    ["limit"] = new JsonObject
                    {
                        ["context"] = 400000,
                        ["output"] = 32768
                    },
                    ["attachment"] = true,
                    ["modalities"] = new JsonObject
                    {
                        ["input"] = new JsonArray("text", "image"),
                        ["output"] = new JsonArray("text")
                    },
                    ["reasoning"] = true,
                    ["options"] = new JsonObject
                    {
                        ["reasoning"] = new JsonObject
                        {
                            ["effort"] = "medium"
                        }
                    }
                }
            },
            ["name"] = "Quotio",
            ["npm"] = "@ai-sdk/anthropic",
            ["options"] = new JsonObject
            {
                ["apiKey"] = apiKey,
                ["baseURL"] = proxyUrl,
                ["litellmProxy"] = true
            }
        };
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

public sealed record OpenCodePlan(
    string TargetPath,
    bool Existed,
    bool HasChanges,
    string Before,
    string After
);

public sealed record OpenCodeInstallResult(
    OpenCodePlan Plan,
    string? BackupPath
);

public sealed record OpenCodeRollbackResult(
    string? RestoredBackupPath,
    string? PreRestoreBackupPath
);
