namespace Quotio.Windows;

public sealed class WindowsAgentAdapter
{
    private static readonly AgentDefinition[] Agents =
    [
        new(
            "claude-code",
            "Claude Code",
            "both",
            ["claude"],
            ["%USERPROFILE%\\.claude\\settings.json"],
            "supported",
            "Windows preview supports read-only detection, guide, and diff preview for Claude Code.",
            "https://docs.anthropic.com/en/docs/claude-code"
        ),
        new(
            "codex",
            "Codex CLI",
            "file",
            ["codex"],
            ["%USERPROFILE%\\.codex\\config.toml"],
            "supported",
            "Windows preview supports read-only detection, guide, and diff preview for Codex CLI.",
            "https://github.com/openai/codex"
        ),
        new(
            "gemini-cli",
            "Gemini CLI",
            "env",
            ["gemini"],
            [],
            "guide-only",
            "Automatic PowerShell profile configuration is not available on Windows yet. Use the manual guide.",
            "https://github.com/google-gemini/gemini-cli"
        ),
        new(
            "opencode",
            "OpenCode",
            "file",
            ["opencode", "oc"],
            ["%LOCALAPPDATA%\\opencode\\opencode.json"],
            "supported",
            "Windows preview supports read-only detection, guide, and diff preview for OpenCode.",
            "https://github.com/sst/opencode"
        ),
        new(
            "factory-droid",
            "Factory Droid",
            "file",
            ["droid", "factory-droid"],
            ["%USERPROFILE%\\.factory\\config.json"],
            "supported",
            "Windows preview supports read-only detection, guide, and diff preview for Factory Droid.",
            "https://docs.factory.ai/welcome"
        ),
        new(
            "amp",
            "Amp CLI",
            "both",
            ["amp"],
            ["%USERPROFILE%\\.config\\amp\\settings.json", "%USERPROFILE%\\.local\\share\\amp\\secrets.json"],
            "supported",
            "Windows preview supports read-only detection, guide, and diff preview for Amp CLI.",
            "https://ampcode.com/manual"
        )
    ];

    public object Handle(string path, string method)
    {
        var normalizedMethod = method.Trim().ToUpperInvariant();
        var parts = path.Trim('/').Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 1 && parts[0] == "agents" && normalizedMethod == "GET")
        {
            return new Dictionary<string, object?>
            {
                ["agents"] = Agents.Select(Descriptor).ToArray()
            };
        }

        if (parts.Length != 3 || parts[0] != "agents")
        {
            throw new InvalidOperationException("Unsupported Windows agents endpoint");
        }

        var agent = FindAgent(parts[1]);
        return parts[2] switch
        {
            "guide" when normalizedMethod == "GET" => Guide(agent),
            "diff" when normalizedMethod == "POST" => Diff(agent),
            "install" when normalizedMethod == "POST" => UnsupportedWrite(agent, "install"),
            "rollback" when normalizedMethod == "POST" => UnsupportedWrite(agent, "rollback"),
            _ => throw new InvalidOperationException("Unsupported Windows agents endpoint")
        };
    }

    private static AgentDefinition FindAgent(string id)
    {
        return Agents.FirstOrDefault(agent => agent.Id == id)
            ?? throw new InvalidOperationException("Unknown Windows agent");
    }

    private static Dictionary<string, object?> Descriptor(AgentDefinition agent)
    {
        return new Dictionary<string, object?>
        {
            ["id"] = agent.Id,
            ["label"] = agent.Label,
            ["binaries"] = agent.Binaries,
            ["config_mode"] = agent.ConfigMode,
            ["platform_support"] = agent.PlatformSupport,
            ["support_message"] = agent.Message,
            ["rollback_available"] = false,
            ["target_paths"] = agent.TargetPaths,
            ["docs_url"] = agent.DocsUrl,
            ["capabilities"] = Capabilities(agent),
            ["caveats"] = Caveats(agent)
        };
    }

    private static Dictionary<string, object?> Guide(AgentDefinition agent)
    {
        return new Dictionary<string, object?>
        {
            ["guide"] = new Dictionary<string, object?>
            {
                ["tool"] = agent.Id,
                ["label"] = agent.Label,
                ["config_mode"] = agent.ConfigMode,
                ["docs_url"] = agent.DocsUrl,
                ["target_paths"] = agent.TargetPaths,
                ["binaries"] = agent.Binaries,
                ["capabilities"] = Capabilities(agent),
                ["steps"] = GuideSteps(agent),
                ["verify"] = agent.Binaries.Select(binary => $"{binary} --version").ToArray(),
                ["caveats"] = Caveats(agent)
            }
        };
    }

    private static Dictionary<string, object?> Diff(AgentDefinition agent)
    {
        var status = Status(agent);
        return new Dictionary<string, object?>
        {
            ["status"] = status,
            ["plan"] = new Dictionary<string, object?>
            {
                ["tool"] = agent.Id,
                ["home_dir"] = HomeDirectory(),
                ["target_paths"] = agent.TargetPaths,
                ["files"] = Array.Empty<object>()
            },
            ["summary"] = "Windows automatic agent configuration is not available in this preview build."
        };
    }

    private static Dictionary<string, object?> UnsupportedWrite(AgentDefinition agent, string action)
    {
        return new Dictionary<string, object?>
        {
            ["status"] = Status(agent),
            ["plan"] = new Dictionary<string, object?>
            {
                ["tool"] = agent.Id,
                ["home_dir"] = HomeDirectory(),
                ["target_paths"] = agent.TargetPaths
            },
            ["manifest"] = new Dictionary<string, object?>
            {
                ["tool"] = agent.Id,
                ["home_dir"] = HomeDirectory()
            },
            ["summary"] = $"Windows {action} is disabled until the native adapter has verified backup and rollback behavior."
        };
    }

    private static Dictionary<string, object?> Status(AgentDefinition agent)
    {
        var binaryPath = FindBinary(agent);
        return new Dictionary<string, object?>
        {
            ["tool"] = agent.Id,
            ["home_dir"] = HomeDirectory(),
            ["target_paths"] = agent.TargetPaths,
            ["installed"] = binaryPath is not null,
            ["configured"] = agent.TargetPaths.Any(path => File.Exists(ExpandPath(path))),
            ["platform_support"] = agent.PlatformSupport,
            ["rollback_available"] = false,
            ["binary_path"] = binaryPath,
            ["message"] = agent.Message
        };
    }

    private static string[] GuideSteps(AgentDefinition agent)
    {
        if (agent.Id == "gemini-cli")
        {
            return
            [
                "Install and verify the Gemini CLI on Windows.",
                "Configure the CLI manually using the official documentation.",
                "Use the Quotio local endpoint when the proxy runtime is running."
            ];
        }

        return
        [
            $"Install and verify {agent.Label} on Windows.",
            "Review the target config paths before editing them manually.",
            "Keep a backup of existing config files before pointing the agent at Quotio."
        ];
    }

    private static string[] Caveats(AgentDefinition agent)
    {
        return agent.PlatformSupport == "guide-only"
            ? ["PowerShell profile writes are not implemented yet."]
            : ["Automatic writes are disabled until backup and rollback behavior is validated on Windows."];
    }

    private static string[] Capabilities(AgentDefinition agent)
    {
        return agent.PlatformSupport == "guide-only"
            ? ["guide"]
            : ["guide", "diff"];
    }

    private static string? FindBinary(AgentDefinition agent)
    {
        foreach (var binary in agent.Binaries)
        {
            var resolved = ResolveExecutable(binary);
            if (resolved is not null)
            {
                return resolved;
            }
        }

        return null;
    }

    private static string? ResolveExecutable(string binary)
    {
        if (Path.IsPathRooted(binary) && File.Exists(binary))
        {
            return binary;
        }

        var path = Environment.GetEnvironmentVariable("PATH");
        if (string.IsNullOrWhiteSpace(path))
        {
            return null;
        }

        foreach (var directory in path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            foreach (var candidate in ExecutableCandidates(binary))
            {
                var fullPath = Path.Combine(directory, candidate);
                if (File.Exists(fullPath))
                {
                    return fullPath;
                }
            }
        }

        return null;
    }

    private static IEnumerable<string> ExecutableCandidates(string binary)
    {
        if (Path.HasExtension(binary))
        {
            yield return binary;
            yield break;
        }

        yield return binary;
        yield return $"{binary}.exe";
        yield return $"{binary}.cmd";
        yield return $"{binary}.bat";
        yield return $"{binary}.ps1";
    }

    private static string ExpandPath(string path)
    {
        return Environment.ExpandEnvironmentVariables(path);
    }

    private static string HomeDirectory()
    {
        return Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    }

    private sealed record AgentDefinition(
        string Id,
        string Label,
        string ConfigMode,
        string[] Binaries,
        string[] TargetPaths,
        string PlatformSupport,
        string Message,
        string DocsUrl
    );
}
