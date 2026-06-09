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

| Agent | ID | Binaries | macOS config paths | Windows state |
| --- | --- | --- | --- | --- |
| Claude Code | `claude-code` | `claude` | `~/.claude/settings.json` | `unknown` until Windows adapter validates the official config path |
| Codex CLI | `codex` | `codex` | `~/.codex/config.toml` | `unknown` until Windows adapter validates the official config path |
| Gemini CLI | `gemini-cli` | `gemini` | shell profile only | `guide-only` until PowerShell/profile writes are implemented |
| Amp CLI | `amp` | `amp` | `~/.config/amp/settings.json`, `~/.local/share/amp/secrets.json` | `unknown` until Windows adapter validates settings and secrets paths |
| OpenCode | `opencode` | `opencode`, `oc` | `~/.config/opencode/opencode.json` | `unknown` until Windows adapter validates the official config path |
| Factory Droid | `factory-droid` | `droid`, `factory-droid` | `~/.factory/config.json` | `unknown` until Windows adapter validates the official config path |

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

The shared Agents route can be enabled only after both hosts expose native
adapter-backed endpoints or bridge methods for descriptor list, detection,
preview diff, install, and rollback. Until then, existing macOS SwiftUI remains
the authoritative write path.
