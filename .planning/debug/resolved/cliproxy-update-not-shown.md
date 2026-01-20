---
status: resolved
trigger: "CLIProxy has an update available but it's not shown in the app's settings/about screen"
created: 2026-01-20T00:00:00Z
updated: 2026-01-20T00:03:00Z
---

## Current Focus

hypothesis: CONFIRMED - checkForUpgrade() is only called during init when autoStartProxy is true
test: Verified by code analysis
expecting: N/A - root cause confirmed
next_action: FIX APPLIED

## Symptoms

expected: CLIProxy update should be visible in the settings/about section of the app
actual: No update indicator shown - app doesn't display that CLIProxy has an update available
errors: No visible errors in the app
reproduction: Open settings screen and look for CLIProxy update indicator - none shown
started: Recently noticed, unclear when it started

## Eliminated

- hypothesis: UI is not displaying upgradeAvailable properly
  evidence: UI code correctly checks `proxyManager.upgradeAvailable` and displays update if true (SettingsScreen.swift lines 1048, 2111, 2428)
  timestamp: 2026-01-20T00:01:30Z

## Evidence

- timestamp: 2026-01-20T00:01:00Z
  checked: CLIProxyManager.swift upgrade-related properties
  found: Has `upgradeAvailable: Bool` and `availableUpgrade: ProxyVersionInfo?` properties. Has `checkForUpgrade()` method that sets these values.
  implication: The mechanism for detecting upgrades exists. Need to check (1) when checkForUpgrade() is called and (2) how UI displays upgradeAvailable

- timestamp: 2026-01-20T00:01:30Z
  checked: QuotaViewModel.swift - when checkForProxyUpgrade() is called
  found: Only called in initializeFullMode() line 230, and ONLY when `autoStartProxy && proxyManager.isBinaryInstalled` is true
  implication: If autoStartProxy is false, upgrade check is NEVER called automatically

- timestamp: 2026-01-20T00:01:45Z
  checked: QuotaViewModel.swift startProxy() function (line 925)
  found: startProxy() does NOT call checkForProxyUpgrade(). Only initializeFullMode() calls it.
  implication: When user manually starts proxy, upgrade check is NOT triggered

## Resolution

root_cause: checkForProxyUpgrade() is only called in initializeFullMode() when autoStartProxy is true. When users manually start the proxy, or when autoStartProxy is disabled, the upgrade check is never performed automatically. The UI correctly displays upgrade availability when upgradeAvailable=true, but this value is never set because checkForUpgrade() is not called.

fix: Added checkForProxyUpgrade() call to startProxy() function (non-blocking, fire-and-forget Task) so upgrade is checked whenever proxy starts, regardless of whether it's auto-start or manual start. Also removed the duplicate call from initializeFullMode() since startProxy() now handles it.

verification: Code changes verified by reviewing the modified QuotaViewModel.swift. The fix ensures:
1. startProxy() now calls checkForProxyUpgrade() after proxy starts successfully
2. The call is wrapped in a detached Task to be non-blocking
3. initializeFullMode() no longer has a duplicate call

files_changed:
  - Quotio/ViewModels/QuotaViewModel.swift (lines 227-228 and 940-946)
