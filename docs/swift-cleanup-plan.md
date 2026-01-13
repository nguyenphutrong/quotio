# Swift Code Cleanup Plan

**Created:** 2026-01-13  
**Branch:** feat/universal-provider-architecture  
**Status:** Planning Complete - Awaiting CLI Proxy Production Readiness

## Overview

Migration plan to remove redundant Swift code after business logic has been ported to the TypeScript `quotio-cli`. This cleanup should only proceed **when the CLI proxy is production-ready**.

### What Was Already Ported

| CLI (TypeScript) | Swift Original | Lines |
|------------------|----------------|-------|
| `quotio-cli/src/services/format-converter.ts` | `Quotio/Services/Proxy/FallbackFormatConverter.swift` | 1305 |
| `quotio-cli/src/services/quota-fetchers/kiro.ts` | `Quotio/Services/QuotaFetchers/KiroQuotaFetcher.swift` | 561 |
| `quotio-cli/src/services/management-api.ts` | `Quotio/Services/ManagementAPIClient.swift` | - |

---

## Phase 1: Preparation (HIGH Priority)

Verify CLI proxy has feature parity before any removal.

| ID | Task | Status |
|----|------|--------|
| 1.1 | Verify `FallbackFormatConverter.ts` handles all 13 providers (OpenAI, Anthropic, Google formats) | [ ] |
| 1.2 | Verify CLI proxy handles fallback trigger detection (429, 5xx, timeout) matching Swift behavior | [ ] |
| 1.3 | Add integration tests for format conversion (OpenAI <-> Anthropic <-> Google) in quotio-cli | [ ] |
| 1.4 | Add integration tests for KiroQuotaFetcher dual auth (Social + IdC) token refresh | [ ] |
| 1.5 | Port remaining quota fetchers to TS: ClaudeCode, Copilot, OpenAI, Gemini, Codex, Antigravity | [ ] |

---

## Phase 2: Move Fallback Logic from Swift to CLI (HIGH Priority)

The fallback/retry logic currently lives in `ProxyBridge.swift`. Move it to CLI for cross-platform support.

| ID | Task | Status |
|----|------|--------|
| 2.1 | Add Virtual Model / fallback chain support to CLI proxy (currently in `ProxyBridge.swift`) | [ ] |
| 2.2 | Move fallback settings API from `FallbackSettingsManager.swift` to CLI config endpoint | [ ] |
| 2.3 | Implement cross-provider retry logic in CLI (retry with different provider on 429/5xx) | [ ] |

---

## Phase 3: Refactor ProxyBridge to Thin Passthrough (MEDIUM Priority)

Once CLI handles fallback, simplify `ProxyBridge.swift` to minimal TCP passthrough.

| ID | Task | Status |
|----|------|--------|
| 3.1 | Remove `FallbackFormatConverter` usage from `ProxyBridge.swift` (CLI handles format conversion) | [ ] |
| 3.2 | Remove fallback/retry logic from `ProxyBridge.swift` (CLI handles retries) | [ ] |
| 3.3 | Keep `ProxyBridge.swift` as thin TCP passthrough with `Connection: close` header only | [ ] |
| 3.4 | Update `RequestTracker` integration to consume metrics from CLI API instead of `ProxyBridge` | [ ] |

---

## Phase 4: Delete Redundant Swift Files (LOW Priority)

Only proceed after Phases 1-3 are verified working.

| ID | File to Delete | Reason | Lines Saved |
|----|----------------|--------|-------------|
| 4.1 | `Quotio/Services/Proxy/FallbackFormatConverter.swift` | Logic now in CLI | ~1100 |
| 4.2 | `Quotio/Services/QuotaFetchers/KiroQuotaFetcher.swift` | Ported to `kiro.ts` | ~300 |
| 4.3 | `Quotio/Services/QuotaFetchers/ClaudeCodeQuotaFetcher.swift` | Once TS equivalent verified | ~200 |
| 4.4 | `Quotio/Services/QuotaFetchers/CopilotQuotaFetcher.swift` | Once TS equivalent verified | ~150 |
| 4.5 | `Quotio/Services/QuotaFetchers/OpenAIQuotaFetcher.swift` | Once TS equivalent verified | ~150 |
| 4.6 | `Quotio/Services/QuotaFetchers/GeminiCLIQuotaFetcher.swift` | Once TS equivalent verified | ~100 |
| 4.7 | `Quotio/Services/QuotaFetchers/CodexCLIQuotaFetcher.swift` | Once TS equivalent verified | ~100 |

**Additional Changes:**
- Update `QuotaViewModel.swift` to use CLI quota endpoints instead of local Swift fetchers

**Estimated Total Deletion:** ~2100+ lines of Swift code

---

## Phase 5: Files to KEEP (DO NOT DELETE)

These Swift files must remain - they handle macOS-specific functionality that cannot be moved to CLI.

| File | Reason |
|------|--------|
| `Quotio/Services/Proxy/CLIProxyManager.swift` | macOS process lifecycle, binary download, auth commands |
| `Quotio/Services/Proxy/ProxyStorageManager.swift` | Versioned binary storage, symlinks, rollback support |
| `Quotio/Services/ProxyBridge.swift` (thinned) | TCP passthrough with `Connection: close` header |
| `Quotio/Services/QuotaFetchers/CursorQuotaFetcher.swift` | Reads local SQLite, macOS-specific, monitor-only |
| `Quotio/Services/QuotaFetchers/TraeQuotaFetcher.swift` | Reads local JSON, macOS-specific, monitor-only |
| `Quotio/Services/StatusBarManager.swift` | macOS menu bar integration |
| `Quotio/Services/StatusBarMenuBuilder.swift` | NSMenu construction |
| `Quotio/Services/NotificationManager.swift` | macOS notifications |
| `Quotio/Services/FallbackSettingsManager.swift` | UI state management (may become thin wrapper) |
| `Quotio/Services/Antigravity/*` | Complex macOS integration (Protobuf, DB, Process, Account) |
| `Quotio/Services/AgentDetectionService.swift` | macOS filesystem scanning |
| `Quotio/Services/AgentConfigurationService.swift` | macOS config file management |
| All UI services | macOS GUI only |

---

## Phase 6: Final Verification (HIGH Priority)

| ID | Test | Status |
|----|------|--------|
| 6.1 | E2E test: Start proxy via Quotio -> run AI agent -> verify request routing works | [ ] |
| 6.2 | E2E test: Fallback scenario - primary provider 429 -> automatic retry to secondary | [ ] |
| 6.3 | E2E test: Token refresh - expired Kiro token -> auto-refresh -> request succeeds | [ ] |
| 6.4 | Verify Swift app builds without errors after deletions (`xcodebuild`) | [ ] |
| 6.5 | Update `AGENTS.md` and documentation to reflect new architecture | [ ] |

---

## Dependency Graph

```
Before Cleanup:
CLIProxyManager
├── ProxyBridge (TCP + Fallback + Format Conversion)
│   ├── FallbackFormatConverter (1100 lines) ← DELETE
│   └── FallbackSettingsManager
├── ProxyStorageManager
└── All QuotaFetchers (Swift) ← MOSTLY DELETE

After Cleanup:
CLIProxyManager
├── ProxyBridge (TCP passthrough only, ~200 lines)
├── ProxyStorageManager
├── CursorQuotaFetcher (monitor-only, KEEP)
└── TraeQuotaFetcher (monitor-only, KEEP)

CLI Proxy (TypeScript):
├── format-converter.ts (handles all format conversion)
├── quota-fetchers/* (handles all provider quotas)
└── routing + fallback logic
```

---

## Notes

- **IDE Monitors** (Cursor, Trae) stay in Swift because they read local SQLite/JSON that's macOS-specific
- **Antigravity suite** stays in Swift due to complex Protobuf DB injection and IDE process management
- **FallbackSettingsManager** may become a thin wrapper that syncs UI state to CLI config
- Test thoroughly on real accounts before deleting any quota fetcher

---

## Commands Reference

```bash
# Verify CLI builds
cd quotio-cli && bun run lint && bun run build

# Verify Swift builds after changes
xcodebuild -project Quotio.xcodeproj -scheme Quotio -configuration Debug build

# Run CLI tests (when added)
cd quotio-cli && bun test
```
