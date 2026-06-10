namespace Quotio.Windows;

using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

public sealed class WindowsAmpConfigPatcher
{
    private readonly string homeDirectory;

    public WindowsAmpConfigPatcher()
        : this(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile))
    {
    }

    public WindowsAmpConfigPatcher(string homeDirectory)
    {
        this.homeDirectory = homeDirectory;
    }

    public string SettingsPath => Path.Combine(homeDirectory, ".config", "amp", "settings.json");

    public string SecretsPath => Path.Combine(homeDirectory, ".local", "share", "amp", "secrets.json");

    public bool IsConfigured()
    {
        if (!File.Exists(SettingsPath) || !File.Exists(SecretsPath))
        {
            return false;
        }

        try
        {
            var settings = JsonNode.Parse(File.ReadAllText(SettingsPath, Encoding.UTF8)) as JsonObject;
            var secrets = JsonNode.Parse(File.ReadAllText(SecretsPath, Encoding.UTF8)) as JsonObject;
            var ampUrl = settings?["amp.url"]?.GetValue<string>();
            return !string.IsNullOrWhiteSpace(ampUrl)
                && !IsDefaultAmpUpstream(ampUrl)
                && secrets?.Any(pair => pair.Key == $"apiKey@{ampUrl}") == true;
        }
        catch (JsonException)
        {
            return false;
        }
    }

    public string? LatestBackupPath()
    {
        return LatestBackupPath(SettingsPath) ?? LatestBackupPath(SecretsPath);
    }

    public AmpPlan BuildPlan(string proxyEndpoint, string apiKey)
    {
        var baseUrl = NormalizeProxyBaseUrl(proxyEndpoint);
        return new AmpPlan(
            [
                BuildFilePlan(SettingsPath, BuildSettingsContent(baseUrl), redact: false),
                BuildFilePlan(SecretsPath, BuildSecretsContent(baseUrl, apiKey), redact: true)
            ]
        );
    }

    public AmpInstallResult Install(string proxyEndpoint, string apiKey)
    {
        var baseUrl = NormalizeProxyBaseUrl(proxyEndpoint);
        var settingsAfter = BuildSettingsContent(baseUrl);
        var secretsAfter = BuildSecretsContent(baseUrl, apiKey);

        Directory.CreateDirectory(Path.GetDirectoryName(SettingsPath)!);
        Directory.CreateDirectory(Path.GetDirectoryName(SecretsPath)!);

        var settingsBackupPath = BackupConfigIfNeeded(SettingsPath);
        var secretsBackupPath = BackupConfigIfNeeded(SecretsPath);
        File.WriteAllText(SettingsPath, settingsAfter, Encoding.UTF8);
        File.WriteAllText(SecretsPath, secretsAfter, Encoding.UTF8);

        return new AmpInstallResult(
            new AmpPlan(
                [
                    BuildFilePlan(SettingsPath, settingsAfter, redact: false),
                    BuildFilePlan(SecretsPath, secretsAfter, redact: true)
                ]
            ),
            settingsBackupPath,
            secretsBackupPath
        );
    }

    public AmpRollbackResult Rollback()
    {
        var settingsRestorePath = LatestBackupPath(SettingsPath);
        var secretsRestorePath = LatestBackupPath(SecretsPath);
        if (settingsRestorePath is null && secretsRestorePath is null)
        {
            return new AmpRollbackResult(null, null, null, null);
        }

        Directory.CreateDirectory(Path.GetDirectoryName(SettingsPath)!);
        Directory.CreateDirectory(Path.GetDirectoryName(SecretsPath)!);

        var settingsPreRestoreBackupPath = settingsRestorePath is null
            ? null
            : BackupConfigIfNeeded(SettingsPath);
        var secretsPreRestoreBackupPath = secretsRestorePath is null
            ? null
            : BackupConfigIfNeeded(SecretsPath);

        if (settingsRestorePath is not null)
        {
            File.Copy(settingsRestorePath, SettingsPath, overwrite: true);
        }

        if (secretsRestorePath is not null)
        {
            File.Copy(secretsRestorePath, SecretsPath, overwrite: true);
        }

        return new AmpRollbackResult(
            settingsRestorePath,
            secretsRestorePath,
            settingsPreRestoreBackupPath,
            secretsPreRestoreBackupPath
        );
    }

    private static AmpFilePlan BuildFilePlan(string path, string after, bool redact)
    {
        var before = File.Exists(path)
            ? File.ReadAllText(path, Encoding.UTF8)
            : "";
        return new AmpFilePlan(
            path,
            File.Exists(path),
            before != after,
            redact ? RedactSecrets(before) : before,
            redact ? RedactSecrets(after) : after
        );
    }

    private static string? LatestBackupPath(string path)
    {
        var directory = Path.GetDirectoryName(path);
        var fileName = Path.GetFileName(path);
        if (string.IsNullOrEmpty(directory) || !Directory.Exists(directory))
        {
            return null;
        }

        return Directory
            .EnumerateFiles(directory, $"{fileName}.backup.*")
            .Select(candidate => new FileInfo(candidate))
            .OrderByDescending(file => file.LastWriteTimeUtc)
            .ThenByDescending(file => file.Name, StringComparer.Ordinal)
            .FirstOrDefault()
            ?.FullName;
    }

    private static string? BackupConfigIfNeeded(string path)
    {
        if (!File.Exists(path))
        {
            return null;
        }

        var baseBackupPath = $"{path}.backup.{DateTimeOffset.UtcNow.ToUnixTimeSeconds()}";
        var backupPath = baseBackupPath;
        var suffix = 1;
        while (File.Exists(backupPath))
        {
            backupPath = $"{baseBackupPath}.{suffix}";
            suffix += 1;
        }

        File.Copy(path, backupPath);
        return backupPath;
    }

    private static string BuildSettingsContent(string baseUrl)
    {
        var root = new JsonObject
        {
            ["amp.url"] = baseUrl
        };
        return root.ToJsonString(new JsonSerializerOptions { WriteIndented = true }) + "\n";
    }

    private static string BuildSecretsContent(string baseUrl, string apiKey)
    {
        var root = new JsonObject
        {
            [$"apiKey@{baseUrl}"] = apiKey
        };
        return root.ToJsonString(new JsonSerializerOptions { WriteIndented = true }) + "\n";
    }

    private static string NormalizeProxyBaseUrl(string endpoint)
    {
        var trimmed = endpoint.Trim().TrimEnd('/');
        return trimmed.EndsWith("/v1", StringComparison.OrdinalIgnoreCase)
            ? trimmed[..^3]
            : trimmed;
    }

    private static bool IsDefaultAmpUpstream(string url)
    {
        return url.Trim().TrimEnd('/').Equals("https://ampcode.com", StringComparison.OrdinalIgnoreCase);
    }

    private static string RedactSecrets(string content)
    {
        if (string.IsNullOrWhiteSpace(content))
        {
            return content;
        }

        try
        {
            var root = JsonNode.Parse(content) as JsonObject;
            if (root is null)
            {
                return content;
            }

            foreach (var key in root.Select(pair => pair.Key).ToArray())
            {
                if (key.StartsWith("apiKey@", StringComparison.OrdinalIgnoreCase))
                {
                    root[key] = "[redacted]";
                }
            }

            return root.ToJsonString(new JsonSerializerOptions { WriteIndented = true });
        }
        catch (JsonException)
        {
            return content;
        }
    }
}

public sealed record AmpPlan(AmpFilePlan[] Files);

public sealed record AmpFilePlan(
    string TargetPath,
    bool Existed,
    bool HasChanges,
    string Before,
    string After
);

public sealed record AmpInstallResult(
    AmpPlan Plan,
    string? SettingsBackupPath,
    string? SecretsBackupPath
);

public sealed record AmpRollbackResult(
    string? RestoredSettingsBackupPath,
    string? RestoredSecretsBackupPath,
    string? PreRestoreSettingsBackupPath,
    string? PreRestoreSecretsBackupPath
);
