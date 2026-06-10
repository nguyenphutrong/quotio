namespace Quotio.Windows;

public sealed class WindowsAgentAdapter
{
    private readonly WindowsHostConfig config;
    private readonly WindowsCodexConfigPatcher codexPatcher;
    private readonly WindowsOpenCodeConfigPatcher openCodePatcher;
    private readonly WindowsFactoryDroidConfigPatcher factoryDroidPatcher;

    public WindowsAgentAdapter()
        : this(new WindowsHostConfig())
    {
    }

    public WindowsAgentAdapter(
        WindowsHostConfig config,
        WindowsCodexConfigPatcher? codexPatcher = null,
        WindowsOpenCodeConfigPatcher? openCodePatcher = null,
        WindowsFactoryDroidConfigPatcher? factoryDroidPatcher = null
    )
    {
        this.config = config;
        this.codexPatcher = codexPatcher ?? new WindowsCodexConfigPatcher();
        this.openCodePatcher = openCodePatcher ?? new WindowsOpenCodeConfigPatcher();
        this.factoryDroidPatcher = factoryDroidPatcher ?? new WindowsFactoryDroidConfigPatcher();
    }

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
            "install" when normalizedMethod == "POST" => agent.Id == "codex"
                ? InstallCodex(agent)
                : agent.Id == "opencode"
                    ? InstallOpenCode(agent)
                    : agent.Id == "factory-droid"
                        ? InstallFactoryDroid(agent)
                : UnsupportedWrite(agent, "install"),
            "rollback" when normalizedMethod == "POST" => agent.Id == "codex"
                ? RollbackCodex(agent)
                : agent.Id == "opencode"
                    ? RollbackOpenCode(agent)
                    : agent.Id == "factory-droid"
                        ? RollbackFactoryDroid(agent)
                : UnsupportedWrite(agent, "rollback"),
            _ => throw new InvalidOperationException("Unsupported Windows agents endpoint")
        };
    }

    private static AgentDefinition FindAgent(string id)
    {
        return Agents.FirstOrDefault(agent => agent.Id == id)
            ?? throw new InvalidOperationException("Unknown Windows agent");
    }

    private Dictionary<string, object?> Descriptor(AgentDefinition agent)
    {
        return new Dictionary<string, object?>
        {
            ["id"] = agent.Id,
            ["label"] = agent.Label,
            ["binaries"] = agent.Binaries,
            ["config_mode"] = agent.ConfigMode,
            ["platform_support"] = agent.PlatformSupport,
            ["support_message"] = agent.Message,
            ["rollback_available"] = RollbackAvailable(agent),
            ["target_paths"] = agent.TargetPaths,
            ["docs_url"] = agent.DocsUrl,
            ["capabilities"] = Capabilities(agent),
            ["caveats"] = Caveats(agent)
        };
    }

    private Dictionary<string, object?> Guide(AgentDefinition agent)
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

    private Dictionary<string, object?> Diff(AgentDefinition agent)
    {
        var status = Status(agent);
        var files = Array.Empty<object>();
        if (agent.Id == "codex")
        {
            var plan = codexPatcher.BuildPlan(config.ProxyEndpoint, RequiredManagementKey());
            files =
            [
                new Dictionary<string, object?>
                {
                    ["target_path"] = plan.TargetPath,
                    ["existed"] = plan.Existed,
                    ["has_changes"] = plan.HasChanges,
                    ["before"] = plan.Before,
                    ["after"] = plan.After
                }
            ];
        }
        else if (agent.Id == "opencode")
        {
            var plan = openCodePatcher.BuildPlan(config.ProxyEndpoint, RequiredManagementKey());
            files =
            [
                new Dictionary<string, object?>
                {
                    ["target_path"] = plan.TargetPath,
                    ["existed"] = plan.Existed,
                    ["has_changes"] = plan.HasChanges,
                    ["before"] = plan.Before,
                    ["after"] = plan.After
                }
            ];
        }
        else if (agent.Id == "factory-droid")
        {
            var plan = factoryDroidPatcher.BuildPlan(config.ProxyEndpoint, RequiredManagementKey());
            files =
            [
                new Dictionary<string, object?>
                {
                    ["target_path"] = plan.TargetPath,
                    ["existed"] = plan.Existed,
                    ["has_changes"] = plan.HasChanges,
                    ["before"] = plan.Before,
                    ["after"] = plan.After
                }
            ];
        }

        return new Dictionary<string, object?>
        {
            ["status"] = status,
            ["plan"] = new Dictionary<string, object?>
            {
                ["tool"] = agent.Id,
                ["home_dir"] = HomeDirectory(),
                ["target_paths"] = agent.TargetPaths,
                ["files"] = files
            },
            ["summary"] = agent.Id == "codex"
                ? "Windows Codex install is available with backup-before-write."
                : agent.Id == "opencode"
                    ? "Windows OpenCode install is available with backup-before-write."
                    : agent.Id == "factory-droid"
                        ? "Windows Factory Droid install is available with backup-before-write."
                    : "Windows automatic agent configuration is not available for this agent in this preview build."
        };
    }

    private Dictionary<string, object?> UnsupportedWrite(AgentDefinition agent, string action)
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

    private Dictionary<string, object?> InstallCodex(AgentDefinition agent)
    {
        var result = codexPatcher.Install(config.ProxyEndpoint, RequiredManagementKey());
        return new Dictionary<string, object?>
        {
            ["status"] = Status(agent),
            ["plan"] = new Dictionary<string, object?>
            {
                ["tool"] = agent.Id,
                ["home_dir"] = HomeDirectory(),
                ["target_paths"] = agent.TargetPaths,
                ["files"] = new object[]
                {
                    new Dictionary<string, object?>
                    {
                        ["target_path"] = result.Plan.TargetPath,
                        ["existed"] = result.Plan.Existed,
                        ["has_changes"] = result.Plan.HasChanges,
                        ["before"] = result.Plan.Before,
                        ["after"] = result.Plan.After
                    }
                }
            },
            ["manifest"] = new Dictionary<string, object?>
            {
                ["tool"] = agent.Id,
                ["home_dir"] = HomeDirectory(),
                ["backup_path"] = result.BackupPath,
                ["config_path"] = codexPatcher.ConfigPath,
                ["catalog_path"] = codexPatcher.CatalogPath
            },
            ["summary"] = "Windows Codex configuration installed with backup-before-write."
        };
    }

    private Dictionary<string, object?> RollbackCodex(AgentDefinition agent)
    {
        var result = codexPatcher.Rollback();
        return new Dictionary<string, object?>
        {
            ["status"] = Status(agent),
            ["manifest"] = new Dictionary<string, object?>
            {
                ["tool"] = agent.Id,
                ["home_dir"] = HomeDirectory(),
                ["restored_backup_path"] = result.RestoredBackupPath,
                ["pre_restore_backup_path"] = result.PreRestoreBackupPath,
                ["config_path"] = codexPatcher.ConfigPath
            },
            ["summary"] = result.RestoredBackupPath is null
                ? "No Windows Codex backup is available to restore."
                : "Windows Codex configuration restored from backup."
        };
    }

    private Dictionary<string, object?> InstallOpenCode(AgentDefinition agent)
    {
        var result = openCodePatcher.Install(config.ProxyEndpoint, RequiredManagementKey());
        return new Dictionary<string, object?>
        {
            ["status"] = Status(agent),
            ["plan"] = new Dictionary<string, object?>
            {
                ["tool"] = agent.Id,
                ["home_dir"] = HomeDirectory(),
                ["target_paths"] = agent.TargetPaths,
                ["files"] = new object[]
                {
                    new Dictionary<string, object?>
                    {
                        ["target_path"] = result.Plan.TargetPath,
                        ["existed"] = result.Plan.Existed,
                        ["has_changes"] = result.Plan.HasChanges,
                        ["before"] = result.Plan.Before,
                        ["after"] = result.Plan.After
                    }
                }
            },
            ["manifest"] = new Dictionary<string, object?>
            {
                ["tool"] = agent.Id,
                ["home_dir"] = HomeDirectory(),
                ["backup_path"] = result.BackupPath,
                ["config_path"] = openCodePatcher.ConfigPath
            },
            ["summary"] = "Windows OpenCode configuration installed with backup-before-write."
        };
    }

    private Dictionary<string, object?> RollbackOpenCode(AgentDefinition agent)
    {
        var result = openCodePatcher.Rollback();
        return new Dictionary<string, object?>
        {
            ["status"] = Status(agent),
            ["manifest"] = new Dictionary<string, object?>
            {
                ["tool"] = agent.Id,
                ["home_dir"] = HomeDirectory(),
                ["restored_backup_path"] = result.RestoredBackupPath,
                ["pre_restore_backup_path"] = result.PreRestoreBackupPath,
                ["config_path"] = openCodePatcher.ConfigPath
            },
            ["summary"] = result.RestoredBackupPath is null
                ? "No Windows OpenCode backup is available to restore."
                : "Windows OpenCode configuration restored from backup."
        };
    }

    private Dictionary<string, object?> InstallFactoryDroid(AgentDefinition agent)
    {
        var result = factoryDroidPatcher.Install(config.ProxyEndpoint, RequiredManagementKey());
        return new Dictionary<string, object?>
        {
            ["status"] = Status(agent),
            ["plan"] = new Dictionary<string, object?>
            {
                ["tool"] = agent.Id,
                ["home_dir"] = HomeDirectory(),
                ["target_paths"] = agent.TargetPaths,
                ["files"] = new object[]
                {
                    new Dictionary<string, object?>
                    {
                        ["target_path"] = result.Plan.TargetPath,
                        ["existed"] = result.Plan.Existed,
                        ["has_changes"] = result.Plan.HasChanges,
                        ["before"] = result.Plan.Before,
                        ["after"] = result.Plan.After
                    }
                }
            },
            ["manifest"] = new Dictionary<string, object?>
            {
                ["tool"] = agent.Id,
                ["home_dir"] = HomeDirectory(),
                ["backup_path"] = result.BackupPath,
                ["config_path"] = factoryDroidPatcher.ConfigPath
            },
            ["summary"] = "Windows Factory Droid configuration installed with backup-before-write."
        };
    }

    private Dictionary<string, object?> RollbackFactoryDroid(AgentDefinition agent)
    {
        var result = factoryDroidPatcher.Rollback();
        return new Dictionary<string, object?>
        {
            ["status"] = Status(agent),
            ["manifest"] = new Dictionary<string, object?>
            {
                ["tool"] = agent.Id,
                ["home_dir"] = HomeDirectory(),
                ["restored_backup_path"] = result.RestoredBackupPath,
                ["pre_restore_backup_path"] = result.PreRestoreBackupPath,
                ["config_path"] = factoryDroidPatcher.ConfigPath
            },
            ["summary"] = result.RestoredBackupPath is null
                ? "No Windows Factory Droid backup is available to restore."
                : "Windows Factory Droid configuration restored from backup."
        };
    }

    private Dictionary<string, object?> Status(AgentDefinition agent)
    {
        var binaryPath = FindBinary(agent);
        return new Dictionary<string, object?>
        {
            ["tool"] = agent.Id,
            ["home_dir"] = HomeDirectory(),
            ["target_paths"] = agent.TargetPaths,
            ["installed"] = binaryPath is not null,
            ["configured"] = agent.Id == "codex"
                ? codexPatcher.IsConfigured()
                : agent.Id == "opencode"
                    ? openCodePatcher.IsConfigured()
                    : agent.Id == "factory-droid"
                        ? factoryDroidPatcher.IsConfigured()
                    : agent.TargetPaths.Any(path => File.Exists(ExpandPath(path))),
            ["platform_support"] = agent.PlatformSupport,
            ["rollback_available"] = RollbackAvailable(agent),
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
        if (agent.Id == "codex" || agent.Id == "opencode" || agent.Id == "factory-droid")
        {
            return ["Automatic writes create timestamped backups before install and rollback."];
        }

        return agent.PlatformSupport == "guide-only"
            ? ["PowerShell profile writes are not implemented yet."]
            : ["Automatic writes are disabled until backup and rollback behavior is validated on Windows."];
    }

    private string[] Capabilities(AgentDefinition agent)
    {
        if (agent.PlatformSupport == "guide-only")
        {
            return ["guide"];
        }

        if (agent.Id != "codex")
        {
            return agent.Id == "opencode" || agent.Id == "factory-droid"
                ? RollbackAvailable(agent)
                    ? ["guide", "diff", "install", "rollback"]
                    : ["guide", "diff", "install"]
                : ["guide", "diff"];
        }

        return RollbackAvailable(agent)
            ? ["guide", "diff", "install", "rollback"]
            : ["guide", "diff", "install"];
    }

    private bool RollbackAvailable(AgentDefinition agent)
    {
        if (agent.Id == "codex")
        {
            return codexPatcher.LatestBackupPath() is not null;
        }

        if (agent.Id == "opencode")
        {
            return openCodePatcher.LatestBackupPath() is not null;
        }

        if (agent.Id == "factory-droid")
        {
            return factoryDroidPatcher.LatestBackupPath() is not null;
        }

        return false;
    }

    private string RequiredManagementKey()
    {
        return !string.IsNullOrWhiteSpace(config.ManagementKey)
            ? config.ManagementKey
            : throw new InvalidOperationException("Windows agent install requires a configured management key.");
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
