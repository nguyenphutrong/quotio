namespace Quotio.Windows;

using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

public sealed class WindowsClaudeCodeConfigPatcher
{
    private const string OpusModel = "gemini-claude-opus-4-5-thinking";
    private const string SonnetModel = "gemini-claude-sonnet-4-5";
    private const string HaikuModel = "gemini-3-flash-preview";
    private readonly string homeDirectory;

    public WindowsClaudeCodeConfigPatcher()
        : this(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile))
    {
    }

    public WindowsClaudeCodeConfigPatcher(string homeDirectory)
    {
        this.homeDirectory = homeDirectory;
    }

    public string ConfigPath => Path.Combine(homeDirectory, ".claude", "settings.json");

    public bool IsConfigured()
    {
        if (!File.Exists(ConfigPath))
        {
            return false;
        }

        try
        {
            var root = JsonNode.Parse(File.ReadAllText(ConfigPath, Encoding.UTF8)) as JsonObject;
            var env = root?["env"] as JsonObject;
            return env?["ANTHROPIC_BASE_URL"] is not null
                && env?["ANTHROPIC_AUTH_TOKEN"] is not null;
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

    public ClaudeCodePlan BuildPlan(string proxyEndpoint, string apiKey)
    {
        var before = File.Exists(ConfigPath)
            ? File.ReadAllText(ConfigPath, Encoding.UTF8)
            : "";
        var after = BuildConfigContent(before, NormalizeProxyBaseUrl(proxyEndpoint), apiKey);

        return new ClaudeCodePlan(
            ConfigPath,
            File.Exists(ConfigPath),
            before != after,
            RedactSecrets(before),
            RedactSecrets(after)
        );
    }

    public ClaudeCodeInstallResult Install(string proxyEndpoint, string apiKey)
    {
        var before = File.Exists(ConfigPath)
            ? File.ReadAllText(ConfigPath, Encoding.UTF8)
            : "";
        var after = BuildConfigContent(before, NormalizeProxyBaseUrl(proxyEndpoint), apiKey);

        Directory.CreateDirectory(Path.GetDirectoryName(ConfigPath)!);

        var backupPath = BackupConfigIfNeeded();
        File.WriteAllText(ConfigPath, after, Encoding.UTF8);

        return new ClaudeCodeInstallResult(
            new ClaudeCodePlan(
                ConfigPath,
                before.Length > 0,
                before != after,
                RedactSecrets(before),
                RedactSecrets(after)
            ),
            backupPath
        );
    }

    public ClaudeCodeRollbackResult Rollback()
    {
        var restorePath = LatestBackupPath();
        if (restorePath is null)
        {
            return new ClaudeCodeRollbackResult(null, null);
        }

        Directory.CreateDirectory(Path.GetDirectoryName(ConfigPath)!);
        var preRestoreBackupPath = BackupConfigIfNeeded();
        File.Copy(restorePath, ConfigPath, overwrite: true);

        return new ClaudeCodeRollbackResult(restorePath, preRestoreBackupPath);
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
        var env = root["env"] as JsonObject;
        if (env is null)
        {
            env = [];
            root["env"] = env;
        }

        env["ANTHROPIC_BASE_URL"] = proxyUrl;
        env["ANTHROPIC_AUTH_TOKEN"] = apiKey;
        env["ANTHROPIC_DEFAULT_OPUS_MODEL"] = OpusModel;
        env["ANTHROPIC_DEFAULT_SONNET_MODEL"] = SonnetModel;
        env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = HaikuModel;
        root["model"] = OpusModel;

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

    private static string NormalizeProxyBaseUrl(string endpoint)
    {
        var trimmed = endpoint.Trim().TrimEnd('/');
        return trimmed.EndsWith("/v1", StringComparison.OrdinalIgnoreCase)
            ? trimmed[..^3]
            : trimmed;
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
            if (root?["env"] is JsonObject env && env["ANTHROPIC_AUTH_TOKEN"] is not null)
            {
                env["ANTHROPIC_AUTH_TOKEN"] = "[redacted]";
            }

            return root?.ToJsonString(new JsonSerializerOptions { WriteIndented = true }) ?? content;
        }
        catch (JsonException)
        {
            return content;
        }
    }
}

public sealed record ClaudeCodePlan(
    string TargetPath,
    bool Existed,
    bool HasChanges,
    string Before,
    string After
);

public sealed record ClaudeCodeInstallResult(
    ClaudeCodePlan Plan,
    string? BackupPath
);

public sealed record ClaudeCodeRollbackResult(
    string? RestoredBackupPath,
    string? PreRestoreBackupPath
);
