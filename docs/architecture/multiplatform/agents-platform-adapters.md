# Agents Platform Adapters

This inventory keeps agent setup behind native adapters instead of assuming
macOS and Windows share shell, path, or backup behavior.

## Shared Contract

- `AgentDescriptor` describes an agent's stable id, display name, config mode,
  binary names, per-platform config paths, support state, backup policy, and
  documentation URL.
- `AgentDetectionStatus` reports the native adapter result for one platform:
  support state, install state, configuration state, rollback availability,
  binary path, version, and an optional user-facing message.
- Support states are string values for now: `supported`, `guide-only`,
  `unsupported`, or `unknown`.

## Current Agent Inventory

| Agent | ID | Binaries | macOS config paths | Windows preview state |
| --- | --- | --- | --- | --- |
| Claude Code | `claude-code` | `claude` | `~/.claude/settings.json` | Read-only descriptor, binary/config detection, guide, and diff preview; writes disabled until backup/rollback validation |
| Codex CLI | `codex` | `codex` | `~/.codex/config.toml` | Descriptor, binary/config detection, guide, diff preview, install, and rollback with timestamped backup-before-write |
| Gemini CLI | `gemini-cli` | `gemini` | shell profile only | `guide-only` until PowerShell/profile writes are implemented |
| Amp CLI | `amp` | `amp` | `~/.config/amp/settings.json`, `~/.local/share/amp/secrets.json` | Read-only descriptor, binary/config detection, guide, and diff preview; writes disabled until backup/rollback validation |
| OpenCode | `opencode` | `opencode`, `oc` | `~/.config/opencode/opencode.json` | Read-only descriptor, binary/config detection, guide, and diff preview; writes disabled until backup/rollback validation |
| Factory Droid | `factory-droid` | `droid`, `factory-droid` | `~/.factory/config.json` | Read-only descriptor, binary/config detection, guide, and diff preview; writes disabled until backup/rollback validation |

## macOS Adapter Rules

- Binary detection must stay bounded. Existing probes use `which` with a
  1-second timeout and `--version` with a 3-second timeout.
- GUI-runtime detection must keep static path fallbacks because GUI apps do not
  inherit the user's interactive shell `PATH`.
- Automatic writes must create a timestamped backup before changing an existing
  config file.
- Backups are append-only. A restore may create a new backup of the current file,
  but it must not overwrite an existing backup.

## Windows Adapter Rules

- Windows support must start as `unknown` or `guide-only` unless a native adapter
  validates the binary lookup, config path, and backup behavior on Windows.
- PowerShell profile writes are separate from POSIX shell profile writes and must
  not reuse `ShellProfileManager`.
- Credentials and secrets belong in the native credential store or the agent's
  documented secret file. Shared UI state may only hold active form input.

## Cutover Gate

The shared Agents route can be enabled for read-only Windows preview use after
the host exposes native adapter-backed descriptor, detection, guide, and diff
preview responses. Codex CLI can use automatic install and rollback after the
Windows adapter verifies backup-before-write and pre-restore backup behavior.
Other agents remain gated until their native Windows adapters expose the same
verified backup-before-write and restore behavior. Until then, existing macOS
SwiftUI remains the authoritative write path for those agents.
