namespace Quotio.Windows;

using System.Text;
using System.Text.Json;

public sealed class WindowsCodexConfigPatcher
{
    private const string ProviderId = "quotio";
    private const string LegacyProviderId = "cliproxyapi";
    private const string ManagedBegin = "# >>> quotio codex managed >>>";
    private const string ManagedEnd = "# <<< quotio codex managed <<<";
    private const string DefaultModel = "gpt-5-codex";
    private static readonly HashSet<string> ManagedTopLevelKeys =
    [
        "model",
        "model_provider",
        "model_catalog_json",
        "model_reasoning_effort"
    ];

    private readonly string homeDirectory;
    private readonly string runtimeDirectory;

    public WindowsCodexConfigPatcher()
        : this(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Quotio",
                "Codex"
            )
        )
    {
    }

    public WindowsCodexConfigPatcher(string homeDirectory, string runtimeDirectory)
    {
        this.homeDirectory = homeDirectory;
        this.runtimeDirectory = runtimeDirectory;
    }

    public string ConfigPath => Path.Combine(homeDirectory, ".codex", "config.toml");

    public string CatalogPath => Path.Combine(runtimeDirectory, "custom_model_catalog.json");

    public bool IsConfigured()
    {
        if (!File.Exists(ConfigPath))
        {
            return false;
        }

        var content = File.ReadAllText(ConfigPath, Encoding.UTF8);
        return content.Contains(ManagedBegin, StringComparison.Ordinal)
            || content.Contains($"[model_providers.{ProviderId}]", StringComparison.Ordinal)
            || content.Contains($"[model_providers.{LegacyProviderId}]", StringComparison.Ordinal);
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

    public CodexPlan BuildPlan(string proxyEndpoint, string apiKey)
    {
        var before = File.Exists(ConfigPath)
            ? File.ReadAllText(ConfigPath, Encoding.UTF8)
            : "";
        var after = BuildConfigContent(before, NormalizeProxyBaseUrl(proxyEndpoint), apiKey);
        return new CodexPlan(
            ConfigPath,
            File.Exists(ConfigPath),
            before != after,
            RedactSecrets(before),
            RedactSecrets(after)
        );
    }

    public CodexInstallResult Install(string proxyEndpoint, string apiKey)
    {
        var before = File.Exists(ConfigPath)
            ? File.ReadAllText(ConfigPath, Encoding.UTF8)
            : "";
        var after = BuildConfigContent(before, NormalizeProxyBaseUrl(proxyEndpoint), apiKey);

        Directory.CreateDirectory(Path.GetDirectoryName(ConfigPath)!);
        Directory.CreateDirectory(runtimeDirectory);

        var backupPath = BackupConfigIfNeeded();
        File.WriteAllText(CatalogPath, BuildCatalogJson(), Encoding.UTF8);
        File.WriteAllText(ConfigPath, after, Encoding.UTF8);

        return new CodexInstallResult(
            new CodexPlan(
                ConfigPath,
                before.Length > 0,
                before != after,
                RedactSecrets(before),
                RedactSecrets(after)
            ),
            backupPath
        );
    }

    public CodexRollbackResult Rollback()
    {
        var restorePath = LatestBackupPath();
        if (restorePath is null)
        {
            return new CodexRollbackResult(null, null);
        }

        Directory.CreateDirectory(Path.GetDirectoryName(ConfigPath)!);
        var preRestoreBackupPath = BackupConfigIfNeeded();
        File.Copy(restorePath, ConfigPath, overwrite: true);

        return new CodexRollbackResult(restorePath, preRestoreBackupPath);
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

    private string BuildConfigContent(string existingContent, string proxyUrl, string apiKey)
    {
        var cleaned = RemoveProviderSections(
            RemoveTopLevelKeys(RemoveManagedBlocks(existingContent))
        ).Trim();

        var managedTop = string.Join('\n',
            ManagedBegin,
            $"model = \"{EscapeTomlString(DefaultModel)}\"",
            $"model_provider = \"{ProviderId}\"",
            $"model_catalog_json = \"{EscapeTomlString(CatalogPath)}\"",
            "model_reasoning_effort = \"high\"",
            ManagedEnd
        );
        var managedProvider = string.Join('\n',
            ManagedBegin,
            $"[model_providers.{ProviderId}]",
            "name = \"Quotio\"",
            $"base_url = \"{EscapeTomlString(proxyUrl)}\"",
            "wire_api = \"responses\"",
            $"experimental_bearer_token = \"{EscapeTomlString(apiKey)}\"",
            "request_max_retries = 3",
            "stream_max_retries = 3",
            "stream_idle_timeout_ms = 600000",
            ManagedEnd
        );

        if (string.IsNullOrWhiteSpace(cleaned))
        {
            return $"{managedTop}\n\n{managedProvider}\n";
        }

        return $"{managedTop}\n\n{cleaned}\n\n{managedProvider}\n";
    }

    private static string RemoveManagedBlocks(string text)
    {
        var output = text;
        while (true)
        {
            var begin = output.IndexOf(ManagedBegin, StringComparison.Ordinal);
            if (begin < 0)
            {
                return output;
            }

            var end = output.IndexOf(ManagedEnd, begin + ManagedBegin.Length, StringComparison.Ordinal);
            if (end < 0)
            {
                throw new InvalidOperationException("Quotio-managed Codex config block is incomplete.");
            }

            var removalEnd = end + ManagedEnd.Length;
            if (removalEnd < output.Length && output[removalEnd] == '\r')
            {
                removalEnd += 1;
            }
            if (removalEnd < output.Length && output[removalEnd] == '\n')
            {
                removalEnd += 1;
            }

            output = output.Remove(begin, removalEnd - begin);
        }
    }

    private static string RemoveTopLevelKeys(string text)
    {
        var output = new List<string>();
        var inTopLevel = true;

        foreach (var line in SplitLines(text))
        {
            var trimmed = line.Trim();
            if (ParseSectionName(trimmed) is not null)
            {
                inTopLevel = false;
            }

            if (inTopLevel && TryTopLevelKey(trimmed, out var key) && ManagedTopLevelKeys.Contains(key))
            {
                continue;
            }

            output.Add(line);
        }

        return string.Join("\n", output);
    }

    private static string RemoveProviderSections(string text)
    {
        var output = new List<string>();
        var skipping = false;

        foreach (var line in SplitLines(text))
        {
            var trimmed = line.Trim();
            var section = ParseSectionName(trimmed);
            if (section is not null)
            {
                skipping = section == $"model_providers.{ProviderId}"
                    || section.StartsWith($"model_providers.{ProviderId}.", StringComparison.Ordinal)
                    || section == $"model_providers.{LegacyProviderId}"
                    || section.StartsWith($"model_providers.{LegacyProviderId}.", StringComparison.Ordinal);
            }

            if (!skipping)
            {
                output.Add(line);
            }
        }

        return string.Join("\n", output);
    }

    private static string[] SplitLines(string text)
    {
        return text.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n');
    }

    private static string? ParseSectionName(string trimmed)
    {
        return trimmed.StartsWith("[", StringComparison.Ordinal)
            && trimmed.EndsWith("]", StringComparison.Ordinal)
            ? trimmed[1..^1].Trim()
            : null;
    }

    private static bool TryTopLevelKey(string trimmed, out string key)
    {
        key = "";
        if (trimmed.Length == 0 || trimmed.StartsWith('#') || !trimmed.Contains('=', StringComparison.Ordinal))
        {
            return false;
        }

        key = trimmed.Split('=', 2)[0].Trim();
        return key.Length > 0;
    }

    private static string NormalizeProxyBaseUrl(string endpoint)
    {
        var trimmed = endpoint.Trim().TrimEnd('/');
        return trimmed.EndsWith("/v1", StringComparison.OrdinalIgnoreCase)
            ? trimmed
            : $"{trimmed}/v1";
    }

    private static string EscapeTomlString(string value)
    {
        return value.Replace("\\", "\\\\", StringComparison.Ordinal)
            .Replace("\"", "\\\"", StringComparison.Ordinal);
    }

    private static string RedactSecrets(string content)
    {
        var output = new List<string>();
        foreach (var line in SplitLines(content))
        {
            var trimmed = line.TrimStart();
            if (trimmed.StartsWith("experimental_bearer_token", StringComparison.Ordinal))
            {
                var prefix = line[..(line.Length - trimmed.Length)];
                output.Add($"{prefix}experimental_bearer_token = \"[redacted]\"");
            }
            else
            {
                output.Add(line);
            }
        }

        return string.Join('\n', output);
    }

    private static string BuildCatalogJson()
    {
        var payload = new
        {
            models = new[]
            {
                new
                {
                    slug = DefaultModel,
                    display_name = "GPT 5 Codex",
                    description = "GPT 5 Codex via Quotio.",
                    context_window = 128000,
                    max_context_window = 128000,
                    auto_compact_token_limit = 102400,
                    truncation_policy = new { mode = "tokens", limit = 40960 },
                    default_reasoning_level = "high",
                    supported_reasoning_levels = new[]
                    {
                        new { effort = "low", description = "Faster, lighter reasoning" },
                        new { effort = "medium", description = "Balanced speed and reasoning" },
                        new { effort = "high", description = "Deeper reasoning" },
                        new { effort = "xhigh", description = "Maximum reasoning where supported" }
                    },
                    supports_parallel_tool_calls = true,
                    shell_type = "shell_command",
                    visibility = "list",
                    supported_in_api = true,
                    isDefault = true
                }
            }
        };

        return JsonSerializer.Serialize(payload, new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase
        }) + "\n";
    }
}

public sealed record CodexPlan(
    string TargetPath,
    bool Existed,
    bool HasChanges,
    string Before,
    string After
);

public sealed record CodexInstallResult(CodexPlan Plan, string? BackupPath);

public sealed record CodexRollbackResult(string? RestoredBackupPath, string? PreRestoreBackupPath);
