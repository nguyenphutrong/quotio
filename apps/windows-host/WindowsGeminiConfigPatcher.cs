namespace Quotio.Windows;

using System.Text;

public sealed class WindowsGeminiConfigPatcher
{
    private const string StartMarker = "# >>> Quotio Gemini CLI configuration >>>";
    private const string EndMarker = "# <<< Quotio Gemini CLI configuration <<<";
    private readonly string homeDirectory;

    public WindowsGeminiConfigPatcher()
        : this(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile))
    {
    }

    public WindowsGeminiConfigPatcher(string homeDirectory)
    {
        this.homeDirectory = homeDirectory;
    }

    public string ProfilePath => Path.Combine(
        homeDirectory,
        "Documents",
        "PowerShell",
        "Microsoft.PowerShell_profile.ps1"
    );

    public bool IsConfigured()
    {
        if (!File.Exists(ProfilePath))
        {
            return false;
        }

        var content = File.ReadAllText(ProfilePath, Encoding.UTF8);
        return content.Contains(StartMarker, StringComparison.Ordinal)
            && content.Contains(EndMarker, StringComparison.Ordinal)
            && (content.Contains("CODE_ASSIST_ENDPOINT", StringComparison.Ordinal)
                || content.Contains("GOOGLE_GEMINI_BASE_URL", StringComparison.Ordinal));
    }

    public string? LatestBackupPath()
    {
        var directory = Path.GetDirectoryName(ProfilePath);
        var fileName = Path.GetFileName(ProfilePath);
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

    public GeminiPlan BuildPlan(string proxyEndpoint, string apiKey)
    {
        var before = File.Exists(ProfilePath)
            ? File.ReadAllText(ProfilePath, Encoding.UTF8)
            : "";
        var after = BuildProfileContent(before, NormalizeProxyBaseUrl(proxyEndpoint), apiKey);

        return new GeminiPlan(
            ProfilePath,
            File.Exists(ProfilePath),
            before != after,
            RedactSecrets(before),
            RedactSecrets(after)
        );
    }

    public GeminiInstallResult Install(string proxyEndpoint, string apiKey)
    {
        var before = File.Exists(ProfilePath)
            ? File.ReadAllText(ProfilePath, Encoding.UTF8)
            : "";
        var after = BuildProfileContent(before, NormalizeProxyBaseUrl(proxyEndpoint), apiKey);

        Directory.CreateDirectory(Path.GetDirectoryName(ProfilePath)!);

        var backupPath = BackupConfigIfNeeded();
        File.WriteAllText(ProfilePath, after, Encoding.UTF8);

        return new GeminiInstallResult(
            new GeminiPlan(
                ProfilePath,
                before.Length > 0,
                before != after,
                RedactSecrets(before),
                RedactSecrets(after)
            ),
            backupPath
        );
    }

    public GeminiRollbackResult Rollback()
    {
        var restorePath = LatestBackupPath();
        if (restorePath is null)
        {
            return new GeminiRollbackResult(null, null);
        }

        Directory.CreateDirectory(Path.GetDirectoryName(ProfilePath)!);
        var preRestoreBackupPath = BackupConfigIfNeeded();
        File.Copy(restorePath, ProfilePath, overwrite: true);

        return new GeminiRollbackResult(restorePath, preRestoreBackupPath);
    }

    private string? BackupConfigIfNeeded()
    {
        if (!File.Exists(ProfilePath))
        {
            return null;
        }

        var baseBackupPath = $"{ProfilePath}.backup.{DateTimeOffset.UtcNow.ToUnixTimeSeconds()}";
        var backupPath = baseBackupPath;
        var suffix = 1;
        while (File.Exists(backupPath))
        {
            backupPath = $"{baseBackupPath}.{suffix}";
            suffix += 1;
        }

        File.Copy(ProfilePath, backupPath);
        return backupPath;
    }

    private static string BuildProfileContent(string existingContent, string proxyUrl, string apiKey)
    {
        var preserved = RemoveExistingBlock(existingContent).TrimEnd();
        var block = string.Join(
            Environment.NewLine,
            [
                StartMarker,
                "$env:GOOGLE_GEMINI_BASE_URL = \"" + EscapePowerShellString(proxyUrl) + "\"",
                "$env:GEMINI_API_KEY = \"" + EscapePowerShellString(apiKey) + "\"",
                EndMarker
            ]
        );

        return string.IsNullOrWhiteSpace(preserved)
            ? block + Environment.NewLine
            : preserved + Environment.NewLine + Environment.NewLine + block + Environment.NewLine;
    }

    private static string RemoveExistingBlock(string content)
    {
        var start = content.IndexOf(StartMarker, StringComparison.Ordinal);
        if (start < 0)
        {
            return content;
        }

        var end = content.IndexOf(EndMarker, start, StringComparison.Ordinal);
        if (end < 0)
        {
            return content;
        }

        end += EndMarker.Length;
        while (end < content.Length && (content[end] == '\r' || content[end] == '\n'))
        {
            end += 1;
        }

        return content.Remove(start, end - start);
    }

    private static string NormalizeProxyBaseUrl(string endpoint)
    {
        var trimmed = endpoint.Trim().TrimEnd('/');
        return trimmed.EndsWith("/v1", StringComparison.OrdinalIgnoreCase)
            ? trimmed[..^3]
            : trimmed;
    }

    private static string EscapePowerShellString(string value)
    {
        return value.Replace("`", "``", StringComparison.Ordinal)
            .Replace("\"", "`\"", StringComparison.Ordinal);
    }

    private static string RedactSecrets(string content)
    {
        if (string.IsNullOrWhiteSpace(content))
        {
            return content;
        }

        var lines = content.Split(["\r\n", "\n"], StringSplitOptions.None);
        for (var index = 0; index < lines.Length; index += 1)
        {
            if (lines[index].Contains("GEMINI_API_KEY", StringComparison.Ordinal))
            {
                lines[index] = "$env:GEMINI_API_KEY = \"[redacted]\"";
            }
        }

        return string.Join(Environment.NewLine, lines);
    }
}

public sealed record GeminiPlan(
    string TargetPath,
    bool Existed,
    bool HasChanges,
    string Before,
    string After
);

public sealed record GeminiInstallResult(
    GeminiPlan Plan,
    string? BackupPath
);

public sealed record GeminiRollbackResult(
    string? RestoredBackupPath,
    string? PreRestoreBackupPath
);
