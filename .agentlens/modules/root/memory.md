# Memory

[← Back to MODULE](MODULE.md) | [← Back to INDEX](../../INDEX.md)

## Summary

| High 🔴 | Medium 🟡 | Low 🟢 |
| 1 | 0 | 13 |

## 🔴 High Priority

### `WARNING` (Quotio/Services/LaunchAtLoginManager.swift:97)

> if app is not in /Applications (registration may fail or be non-persistent)

## 🟢 Low Priority

### `NOTE` (Quotio/Services/AgentDetectionService.swift:16)

> Only checks file existence (metadata), does NOT read file content

### `NOTE` (Quotio/Services/AgentDetectionService.swift:73)

> --version is intentionally not fetched here. It is unused in the UI and

### `NOTE` (Quotio/Services/AgentDetectionService.swift:94)

> May not work in GUI apps due to limited PATH inheritance

### `NOTE` (Quotio/Services/AgentDetectionService.swift:100)

> Only checks file existence (metadata), does NOT read file content

### `NOTE` (Quotio/Services/CLIExecutor.swift:33)

> Only checks file existence (metadata), does NOT read file content

### `NOTE` (Quotio/ViewModels/AgentSetupViewModel.swift:628)

> Actual fallback resolution happens at request time in ProxyBridge

### `NOTE` (Quotio/ViewModels/QuotaViewModel.swift:280)

> checkForProxyUpgrade() is now called inside startProxy()

### `NOTE` (Quotio/ViewModels/QuotaViewModel.swift:353)

> Cursor and Trae are NOT auto-refreshed - user must use "Scan for IDEs" (issue #29)

### `NOTE` (Quotio/ViewModels/QuotaViewModel.swift:361)

> Cursor and Trae removed from auto-refresh to address privacy concerns (issue #29)

### `NOTE` (Quotio/ViewModels/QuotaViewModel.swift:1193)

> Cursor and Trae removed from auto-refresh (issue #29)

### `NOTE` (Quotio/ViewModels/QuotaViewModel.swift:1238)

> Cursor and Trae require explicit user scan (issue #29)

### `NOTE` (Quotio/ViewModels/QuotaViewModel.swift:1248)

> Cursor and Trae removed - require explicit scan (issue #29)

### `NOTE` (Quotio/ViewModels/QuotaViewModel.swift:1303)

> Don't call detectActiveAccount() here - already set by switch operation

