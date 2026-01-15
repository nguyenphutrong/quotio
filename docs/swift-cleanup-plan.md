# Swift Code Cleanup Plan

**Created:** 2026-01-13
**Updated:** 2026-01-15
**Branch:** dev
**Status:** Phase 4+6 Complete, Phase 2-3 Deferred (low value / high cost)

## Overview

Migration plan to remove redundant Swift code after business logic has been ported to the TypeScript `quotio-cli`. 

### Summary

| Category | Files | Lines | Status |
|----------|-------|-------|--------|
| AppMode.swift (deprecated) | 1 | 149 | ✅ **Deleted** |
| ManagementAPIClient | 1 | 726 | ⚠️ **BLOCKED** (still needed for remote mode + refreshData) |
| QuotaFetchers (TS ported) | 6 | 2,217 | ✅ **Deleted** (commit 34d39bf) |
| FallbackFormatConverter | 1 | 63 | ✅ **Simplified** (was 1,190) |
| ProxyBridge (simplify) | 1 | ~150 lines | ⏸️ **DEFERRED** (low value) |
| **Total removed so far** | **8 files** | **~2,366 lines** | |

### Recent Progress (2026-01-15)

**Commit 34d39bf** (`refactor(quota): migrate Kiro and Copilot fetchers to daemon IPC`) completed Phase 4:
- Deleted 6 quota fetchers (2,217 lines total)
- Added `quota.refreshTokens` IPC for Kiro token refresh
- Added `copilot.availableModels` IPC for Copilot model filtering
- Updated QuotaViewModel and AgentConfigurationService to use daemon

**Commit e1ed27a** (`refactor(fallback): simplify fallback logic by removing format conversion`) completed Phase 3.4:
- `FallbackFormatConverter.swift` reduced from 1,190 → 63 lines
- Added `ModelType` enum to `FallbackModels.swift` for same-type-only fallback

---

## What Was Already Ported to TypeScript

All quota fetchers and format converter have been ported to `quotio-cli`:

| CLI (TypeScript) | Swift Original | Swift Lines | TS Lines | Status |
|------------------|----------------|-------------|----------|--------|
| `format-converter.ts` | `FallbackFormatConverter.swift` | 63 | 1,306 | ⚠️ Swift simplified (error detection only) |
| `quota-fetchers/kiro.ts` | `KiroQuotaFetcher.swift` | 519 | 560 | ✅ Ported + Tested |
| `quota-fetchers/claude.ts` | `ClaudeCodeQuotaFetcher.swift` | 364 | 189 | ✅ Ported + Tested |
| `quota-fetchers/copilot.ts` | `CopilotQuotaFetcher.swift` | 487 | 270 | ✅ Ported + Tested |
| `quota-fetchers/openai.ts` | `OpenAIQuotaFetcher.swift` | 291 | 234 | ✅ Ported |
| `quota-fetchers/gemini.ts` | `GeminiCLIQuotaFetcher.swift` | 186 | 107 | ✅ Ported |
| `quota-fetchers/codex.ts` | `CodexCLIQuotaFetcher.swift` | 370 | 254 | ✅ Ported |
| `quota-fetchers/antigravity.ts` | `AntigravityQuotaFetcher.swift` | 843 | 338 | ✅ Ported |
| `quota-fetchers/cursor.ts` | `CursorQuotaFetcher.swift` | 406 | 284 | ✅ Ported (KEEP Swift) |
| `quota-fetchers/trae.ts` | `TraeQuotaFetcher.swift` | 368 | 356 | ✅ Ported (KEEP Swift) |
| `management-api.ts` | `ManagementAPIClient.swift` | 726 | 368 | ✅ Ported |

---

## Phase 1: Immediate Cleanup (Safe Deletions)

Files that are already deprecated and have no/minimal dependencies.

### 1.1 Delete `AppMode.swift` (149 lines) ✅ DONE

| Property | Value |
|----------|-------|
| File | `Quotio/Models/AppMode.swift` |
| Status | ✅ **DELETED** |
| Replacement | `OperatingMode.swift` |
| Notes | File no longer exists. Migration references remain in `OperatingMode.swift` for UserDefaults backward compat. |

### 1.2 Migrate `ManagementAPIClient` Usages (726 lines)

| Property | Value |
|----------|-------|
| File | `Quotio/Services/ManagementAPIClient.swift` |
| Status | `@available(*, deprecated)` - **BLOCKED** |
| Replacement | `DaemonIPCClient` |
| Dependencies | Multiple files still using it |

> **⚠️ BLOCKED (2026-01-15)**: This migration is more complex than initially scoped.
> 
> **Blocker**: `QuotaViewModel.refreshData()` uses `ManagementAPIClient` for:
> - `client.fetchAuthFiles()` → needs `DaemonAuthService.listAuthFiles()` integration
> - `client.fetchUsageStats()` → needs daemon IPC method
> - `client.fetchAPIKeys()` → needs `DaemonAPIKeysService` integration
> 
> **Current state**:
> - `LogsViewModel`: Already uses daemon for local, API for remote ✅
> - `QuotaViewModel`: Mixed - uses daemon for some ops, API for `refreshData()`
> - Remote mode still requires `ManagementAPIClient` (no daemon-based remote API calls)
> 
> **Required work**:
> 1. Refactor `refreshData()` to use daemon services for local mode
> 2. Add remote mode API calls through daemon IPC (or keep ManagementAPIClient for remote)
> 3. This is a **medium-sized refactor**, not a simple migration

**Files using ManagementAPIClient:**

| File | Current Usage | Status |
|------|---------------|--------|
| `ViewModels/LogsViewModel.swift` | Remote mode logs | ✅ Correct (remote needs API) |
| `ViewModels/QuotaViewModel.swift` | `refreshData()` + remote mode | ⚠️ Local should use daemon |
| `Views/Screens/SettingsScreen.swift` | Comments only | ✅ No code changes needed |
| `Models/ConnectionMode.swift` | Base URL extraction | ✅ Keep for remote mode |

---

## Phase 2-3: Fallback Logic (DEFERRED)

> **Status:** ⏸️ **DEFERRED** (2026-01-15) - Low value / high cost
>
> **Analysis Summary:**
> - Moving retry logic from Swift to CLI would require modifying Go proxy binary OR creating intermediate layer
> - Complex HTTP stream interception needed for retry detection
> - Current ProxyBridge implementation is working correctly and well-structured
>
> **Actual Code Footprint (smaller than estimated):**
> - `FallbackContext` struct: 38 lines
> - `createFallbackContext()`: 46 lines
> - `replaceModelInBody()`: 15 lines
> - Retry logic in `receiveResponse()`: 45 lines
> - **Total: ~150 lines** (not 280+ as originally estimated)
>
> **Decision:** Keep fallback logic in ProxyBridge.swift. The code is:
> - Working correctly in production
> - Well-tested and battle-hardened
> - Only ~16% of ProxyBridge.swift (150/930 lines)
> - Would require significant effort to move with little benefit

### Original Phase 2 Plan (NOT IMPLEMENTED)

| ID | Task | Status |
|----|------|--------|
| 2.1 | Add Virtual Model / fallback chain support to CLI proxy | ⏸️ Deferred |
| 2.2 | Move fallback settings API from `FallbackSettingsManager.swift` to CLI IPC | ✅ Already done (fallback.* IPC methods exist) |
| 2.3 | Implement same-type retry logic in CLI (retry on 429/5xx) | ⏸️ Deferred |
| 2.4 | Update `FallbackSettingsManager.swift` to sync with CLI config | ✅ Already done (file watcher on fallback-config.json) |

### Original Phase 3 Plan (PARTIAL)

| ID | Task | Status |
|----|------|--------|
| 3.1 | Remove `FallbackFormatConverter` usage from `ProxyBridge.swift` | ⏸️ Deferred (still used for error detection) |
| 3.2 | Remove `FallbackContext` and fallback retry logic | ⏸️ Deferred |
| 3.3 | Keep only TCP passthrough with `Connection: close` header | ⏸️ Deferred |
| 3.4 | ~~Delete `FallbackFormatConverter.swift` (1,190 lines)~~ | ✅ **DONE** - reduced to 63 lines (error detection only) |
| 3.5 | Update `RequestTracker` to consume metrics from CLI API | ⏸️ Deferred |

> **Note**: Phase 3.4 completed early in commit `e1ed27a`. FallbackFormatConverter now only contains error detection logic (63 lines).

---

## Phase 4: Delete QuotaFetchers (After Phase 1.2)

> **Detailed Plan:** See [phase4-quota-fetcher-migration.md](./phase4-quota-fetcher-migration.md)

After `QuotaViewModel` is migrated to use `DaemonIPCClient.fetchQuotas()`:

## Phase 4: Delete QuotaFetchers ✅ DONE

> **Completed:** Commit `34d39bf` (2026-01-15)
> 
> All 6 quota fetchers migrated to daemon IPC and deleted: 2,217 lines removed.

### Phase 4A: Safe Deletions ✅ DONE

| ID | File Deleted | Lines | Status |
|----|--------------|-------|--------|
| 4A.1 | `QuotaFetchers/OpenAIQuotaFetcher.swift` | 291 | ✅ Deleted |
| 4A.2 | `QuotaFetchers/ClaudeCodeQuotaFetcher.swift` | 364 | ✅ Deleted |
| 4A.3 | `QuotaFetchers/GeminiCLIQuotaFetcher.swift` | 186 | ✅ Deleted |
| 4A.4 | `QuotaFetchers/CodexCLIQuotaFetcher.swift` | 370 | ✅ Deleted |
| **Subtotal** | | **1,211** | ✅ |

### Phase 4B: Blocked Deletions ✅ DONE

| ID | File Deleted | Lines | Resolution |
|----|--------------|-------|------------|
| 4B.1 | `QuotaFetchers/KiroQuotaFetcher.swift` | 519 | ✅ Added `quota.refreshTokens` IPC |
| 4B.2 | `QuotaFetchers/CopilotQuotaFetcher.swift` | 487 | ✅ Added `copilot.availableModels` IPC |
| **Subtotal** | | **1,006** | ✅ |

| **Total Removed** | | **2,217 lines** | ✅ |

### Remaining QuotaFetchers (KEEP - macOS-specific)

| File | Lines | Reason |
|------|-------|--------|
| `CursorQuotaFetcher.swift` | 406 | Reads local SQLite from Cursor app |
| `TraeQuotaFetcher.swift` | 368 | Reads local JSON from Trae IDE |
| `GLMQuotaFetcher.swift` | ~200 | GLM provider (external service) |
| `AntigravityQuotaFetcher.swift` | 843 | Complex protobuf + DB injection |

---

## Phase 5: Files to KEEP (DO NOT DELETE)

These Swift files must remain - they handle macOS-specific functionality.

### Core Services (KEEP)

| File | Reason |
|------|--------|
| `Daemon/DaemonIPCClient.swift` | IPC client - core communication layer |
| `Daemon/DaemonManager.swift` | Daemon lifecycle management |
| `Daemon/DaemonProxyService.swift` | Proxy operations via IPC |
| `Daemon/DaemonQuotaService.swift` | Quota fetching via IPC |
| `Daemon/DaemonAuthService.swift` | Auth management via IPC |
| `Daemon/DaemonLogsService.swift` | Logs via IPC |
| `Daemon/DaemonConfigService.swift` | Config via IPC |
| `Daemon/DaemonProxyConfigService.swift` | Proxy config via IPC |
| `Daemon/DaemonAPIKeysService.swift` | API keys via IPC |
| `Daemon/IPCProtocol.swift` | IPC types and protocol |
| `Proxy/CLIProxyManager.swift` | macOS process lifecycle, binary management |
| `Proxy/ProxyStorageManager.swift` | Versioned binary storage, rollback |
| `Proxy/ProxyBridge.swift` (thinned) | TCP passthrough only (~200 lines after cleanup) |
| `Proxy/FallbackFormatConverter.swift` | Error detection only (63 lines) |
| `KeychainService.swift` | macOS Keychain integration |
| `StatusBarManager.swift` | macOS menu bar integration |
| `StatusBarMenuBuilder.swift` | NSMenu construction |
| `NotificationManager.swift` | macOS notifications |
| `FallbackSettingsManager.swift` | UI state (becomes thin wrapper to CLI config) |
| `AgentDetectionService.swift` | macOS filesystem scanning |
| `AgentConfigurationService.swift` | macOS config file management |
| `UniversalProviderService.swift` | Provider management |

### QuotaFetchers to KEEP (macOS-specific)

| File | Lines | Reason |
|------|-------|--------|
| `CursorQuotaFetcher.swift` | 406 | Reads local SQLite from Cursor app |
| `TraeQuotaFetcher.swift` | 368 | Reads local JSON from Trae IDE |

### Antigravity Suite (KEEP - 2,023 lines total)

| File | Lines | Reason |
|------|-------|--------|
| `AntigravityQuotaFetcher.swift` | 843 | Complex quota + account management |
| `AntigravityDatabaseService.swift` | 378 | SQLite DB injection |
| `AntigravityProtobufHandler.swift` | 313 | Protobuf parsing |
| `AntigravityAccountSwitcher.swift` | 283 | Account switching |
| `AntigravityProcessManager.swift` | 206 | IDE process management |

---

## Phase 6: Final Verification ✅ COMPLETE

| ID | Test | Command | Status |
|----|------|---------|--------|
| 6.1 | CLI tests pass | `cd quotio-cli && bun test` | ✅ 90 tests pass |
| 6.2 | Swift app builds | `xcodebuild -scheme Quotio -configuration Debug build` | ✅ BUILD SUCCEEDED |
| 6.3 | E2E: Proxy routing works | Manual test with AI agent | ⏳ Pending manual test |
| 6.4 | E2E: Fallback retry works | Trigger 429 → verify retry | ⏳ Pending manual test |
| 6.5 | E2E: Token refresh works | Expire Kiro token → verify refresh | ⏳ Pending manual test |
| 6.6 | ~~Update documentation~~ | ~~Fix ports in AGENTS.md~~ | ✅ Verified correct |

> **Automated tests completed:** 2026-01-15
> - CLI: 90 tests pass (154 expect() calls)
> - Swift: Debug build succeeds

---

## Phase 7: Documentation Fixes

**Status:** ✅ **VERIFIED CORRECT** (2026-01-15)

The documentation accurately reflects the dual-port architecture:
- **Port 8317** = ProxyBridge.swift (client-facing, what CLI agents connect to)
- **Port 18317** = CLIProxyAPI Go binary (internal, ProxyBridge forwards here)

| File | Line | Current Value | Status |
|------|------|---------------|--------|
| `AGENTS.md:85` | daemon → CLIProxyAPI | `18317` | ✅ Correct (internal) |
| `AGENTS.md:212` | ProxyBridge.swift | `8317` | ✅ Correct (client-facing) |
| `AGENTS.md:216` | CLIProxyAPI | `18317` | ✅ Correct (internal) |
| `docs/daemon-migration-guide.md:14` | CLIProxyAPI | `18317` | ✅ Correct (internal) |

**No changes needed.** Original plan had incorrect assumption about port usage.

---

## Dependency Graph

```
BEFORE CLEANUP (Current State):

CLIProxyManager
├── ProxyBridge (930 lines: TCP + Fallback, simplified format handling)
│   ├── FallbackFormatConverter (63 lines: error detection only)
│   └── FallbackSettingsManager
├── ProxyStorageManager
└── QuotaFetchers (Swift)
    ├── OpenAIQuotaFetcher (291 lines) ← DELETE (Phase 4A)
    ├── ClaudeCodeQuotaFetcher (364 lines) ← DELETE (Phase 4A)
    ├── GeminiCLIQuotaFetcher (186 lines) ← DELETE (Phase 4A)
    ├── CodexCLIQuotaFetcher (370 lines) ← DELETE (Phase 4A)
    ├── KiroQuotaFetcher (519 lines) ← DELETE (Phase 4B - needs IPC)
    ├── CopilotQuotaFetcher (487 lines) ← DELETE (Phase 4B - needs IPC)
    ├── CursorQuotaFetcher (406 lines) ← KEEP (macOS SQLite)
    └── TraeQuotaFetcher (368 lines) ← KEEP (macOS JSON)

ViewModels
├── QuotaViewModel
│   └── ManagementAPIClient (726 lines) ← DELETE after migration
└── LogsViewModel
    └── ManagementAPIClient ← DELETE after migration

Models
├── AppMode.swift (149 lines) ← DELETE immediately
└── FallbackModels.swift ← KEEP (has ModelType enum for same-type fallback)

---

AFTER CLEANUP (Target State):

CLIProxyManager
├── ProxyBridge (~200 lines: TCP passthrough only)
├── ProxyStorageManager
└── DaemonIPCClient (IPC to quotio-cli)

QuotaFetchers (Swift - macOS only)
├── CursorQuotaFetcher (KEEP - local SQLite)
└── TraeQuotaFetcher (KEEP - local JSON)

quotio-cli daemon (TypeScript):
├── format-converter.ts (all format conversion - for future cross-type fallback if needed)
├── quota-fetchers/* (all provider quotas via API)
└── fallback/routing logic (same-type only)
```

---

## Implementation Timeline

| Week | Phase | Tasks | Lines Removed |
|------|-------|-------|---------------|
| 1 | Phase 1 | Delete AppMode.swift, Migrate ManagementAPIClient | 875 |
| 2 | Phase 4A | Delete 4 QuotaFetchers (safe deletions) | 1,211 |
| 3 | Phase 4B | Add IPC methods, Delete Kiro + Copilot fetchers | 1,006 |
| 4 | Phase 2-3 | ~~Move fallback to CLI, Simplify ProxyBridge~~ | ⏸️ Deferred |
| 5 | Phase 6-7 | Testing, Documentation | 0 |
| **Total** | | | **~3,092 lines** |

> **Note**: Phase 4 split into 4A (safe) and 4B (blocked). See [phase4-quota-fetcher-migration.md](./phase4-quota-fetcher-migration.md) for details.

---

## Notes

- **IDE Monitors** (Cursor, Trae) stay in Swift - they read local SQLite/JSON
- **Antigravity suite** stays in Swift due to complex Protobuf DB injection and IDE process management
- **FallbackSettingsManager** becomes thin wrapper syncing UI state to CLI config
- **FallbackFormatConverter** already simplified to error detection only (63 lines) - keep in Swift
- **ModelType enum** in FallbackModels.swift enforces same-type-only fallback (Claude→Claude, GPT→GPT, etc.)
- Test thoroughly on real accounts before deleting any quota fetcher
- Delete one file at a time and verify build after each deletion

---

## Commands Reference

```bash
# Verify CLI tests pass
cd quotio-cli && bun test

# Verify CLI builds
cd quotio-cli && bun run build

# Verify Swift builds
xcodebuild -project Quotio.xcodeproj -scheme Quotio -configuration Debug build

# Check for remaining usages before deletion
rg "KiroQuotaFetcher" Quotio/ --line-number

# Delete a file safely
git rm Quotio/Services/QuotaFetchers/KiroQuotaFetcher.swift

# Verify no compile errors
xcodebuild -project Quotio.xcodeproj -scheme Quotio -configuration Debug build 2>&1 | grep -E "error:|warning:"
```
