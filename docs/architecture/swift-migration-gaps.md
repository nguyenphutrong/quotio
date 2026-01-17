# Swift to Tauri Migration Gap Analysis

**Status:** Analysis Complete  
**Date:** 2026-01-17  
**Related Issues:** QUO-8

## Overview

This document analyzes the Swift macOS app services and identifies what needs to be migrated or reimplemented for the Tauri v2 cross-platform app.

## Service Classification

### Category 1: Already in Daemon (No Migration Needed)

These Swift services are thin wrappers around daemon IPC calls. The logic already exists in `quotio-cli`:

| Swift Service | Daemon Handler | Status |
|--------------|----------------|--------|
| `DaemonIPCClient` | N/A (transport) | Replace with HTTP client |
| `DaemonProxyConfigService` | `proxyConfig.*` | ✅ Ready |
| `DaemonAuthService` | `auth.*`, `oauth.*` | ✅ Ready |
| `DaemonQuotaService` | `quota.*` | ✅ Ready |
| `DaemonAPIKeysService` | `apiKeys.*` | ✅ Ready |
| `DaemonLogsService` | `logs.*` | ✅ Ready |
| `DaemonProxyService` | `proxy.*` | ✅ Ready |
| `DaemonAgentService` | `agent.*` | ✅ Ready |
| `DaemonConfigService` | `config.*` | ✅ Ready |
| `DaemonStatsService` | `stats.*` | ✅ Ready |
| `DaemonManager` | `daemon.*` | ✅ Ready |

### Category 2: Shared File-Based Config (No Migration Needed)

These use shared config files that both Swift and CLI can access:

| Swift Service | Config File | Status |
|--------------|-------------|--------|
| `FallbackSettingsManager` | `~/.config/quotio/fallback-config.json` | ✅ Shared |

### Category 3: macOS-Specific (Cannot Migrate)

These are inherently macOS-only and need platform-specific replacements:

| Swift Service | Purpose | Tauri Equivalent |
|--------------|---------|------------------|
| `StatusBarManager` | Menu bar icon | Tauri system tray API |
| `StatusBarMenuBuilder` | Menu construction | Tauri tray menu |
| `NotificationManager` | macOS notifications | Tauri notification plugin |
| `LaunchAtLoginManager` | Login item | Tauri autostart plugin |
| `KeychainService` | Secure storage | Tauri stronghold/keyring plugin |
| `UpdaterService` | Sparkle updates | Tauri updater |
| `LanguageManager` | Localization | i18n library (i18next) |

### Category 4: Needs Migration to Daemon

These have logic in Swift that should move to the daemon:

| Swift Service | Current Location | Migration Target |
|--------------|------------------|------------------|
| `ProxyBridge` | Swift TCP proxy | Keep in Swift/Rust (performance) |
| `CLIProxyManager` | Swift process mgmt | Already in daemon (`proxy-process/`) |
| `ProxyStorageManager` | Swift binary mgmt | Already in daemon (not needed for Tauri) |
| `ShellProfileManager` | Swift shell editing | Already in daemon (`agent-detection/`) |
| `AgentDetectionService` | Swift agent scan | Already in daemon (`agent.detect`) |
| `AgentConfigurationService` | Swift config write | Already in daemon (`agent.configure`) |

### Category 5: Quota Fetchers (Complex - Needs Analysis)

These scrape provider-specific data and may need careful migration:

| Swift Fetcher | Data Source | Daemon Support |
|--------------|-------------|----------------|
| `AntigravityQuotaFetcher` | Protobuf + SQLite | ❌ Swift only (needs migration) |
| `ClaudeCodeQuotaFetcher` | Filesystem | ✅ In daemon |
| `CopilotQuotaFetcher` | OAuth API | ✅ In daemon |
| `CursorQuotaFetcher` | SQLite | ❌ Swift only (needs migration) |
| `TraeQuotaFetcher` | SQLite | ❌ Swift only (needs migration) |
| `OpenAIQuotaFetcher` | OAuth API | ✅ In daemon |
| `GeminiCLIQuotaFetcher` | Filesystem | ✅ In daemon |
| `GLMQuotaFetcher` | API | ✅ In daemon |

## Migration Recommendations

### High Priority (Blocking for MVP)

1. **TypeScript Daemon Client** (QUO-6)
   - Replace `DaemonIPCClient.swift` with TypeScript HTTP client
   - Type-safe wrapper for all 50+ IPC methods

2. **Tauri System Tray**
   - Use `tauri-plugin-system-tray` for menu bar equivalent
   - Port `StatusBarMenuBuilder` menu structure to Tauri format

3. **Tauri Notifications**
   - Use `tauri-plugin-notification`
   - Port notification templates from `NotificationManager`

### Medium Priority (Post-MVP)

4. **Cursor/Trae Quota Fetchers**
   - SQLite reading needs to move to daemon
   - Add `quota.fetchCursor` and `quota.fetchTrae` IPC methods

5. **Antigravity Suite**
   - Complex protobuf + SQLite operations
   - Consider keeping macOS-only initially

6. **Secure Storage**
   - Use `tauri-plugin-stronghold` for API key storage
   - Port `KeychainService` functionality

### Low Priority (Nice to Have)

7. **Auto-start**
   - Use `tauri-plugin-autostart`

8. **Localization**
   - Use i18next or similar
   - Port String Catalogs to JSON format

## Architecture Comparison

### Current Swift Architecture
```
Swift App
├── ViewModels (QuotaViewModel, LogsViewModel)
│   └── Uses Daemon*Service wrappers
├── Services/Daemon/ (IPC wrappers)
│   └── DaemonIPCClient (Unix Socket)
├── Services/ (macOS-specific)
│   ├── StatusBarManager
│   ├── NotificationManager
│   └── KeychainService
└── Views/ (SwiftUI)
```

### Target Tauri Architecture
```
Tauri App
├── Frontend (React/Vue)
│   ├── stores/ (Zustand/Pinia state)
│   └── @quotio/client (HTTP client)
├── src-tauri/ (Rust)
│   ├── tray.rs (system tray)
│   ├── commands.rs (invoke handlers)
│   └── sidecar.rs (daemon lifecycle)
└── quotio-cli (sidecar)
    └── HTTP Server (port 18318)
```

## Gap Summary

| Category | Count | Migration Effort |
|----------|-------|------------------|
| Already in Daemon | 11 | None |
| Shared Config | 1 | None |
| macOS-Specific | 7 | Tauri plugins |
| Needs Migration | 6 | Already done |
| Quota Fetchers | 8 | 3 need migration |

**Total Swift Services:** 49  
**Ready for Tauri:** ~40 (82%)  
**Needs Work:** ~9 (18%)

## Next Steps

1. ✅ HTTP server added to daemon (QUO-3)
2. ⏳ Create TypeScript client library (QUO-6)
3. ⏳ Set up Tauri project structure
4. ⏳ Implement system tray
5. ⏳ Migrate Cursor/Trae quota fetchers to daemon
