---
status: investigating
trigger: "CLIProxyAPI has an update available but it's not shown in the app's settings/about screen"
created: 2026-01-20T00:00:00Z
updated: 2026-01-20T00:02:00Z
---

## Current Focus

hypothesis: ProxyVersionInfo init fails silently when SHA256 checksum from GitHub asset is missing or malformed
test: Trace ProxyVersionInfo(from:asset:) initialization - check if asset.sha256Checksum returns nil
expecting: If sha256Checksum is nil, ProxyVersionInfo returns nil, causing upgradeAvailable to stay false
next_action: Verify that sha256Checksum extraction from digest field works correctly

## Symptoms

expected: CLIProxyAPI update should be visible in the settings/about section of the app
actual: No update indicator shown for CLIProxyAPI - app doesn't display that CLIProxyAPI has an update available
errors: No visible errors in the app
reproduction: Open settings screen and look for CLIProxyAPI update indicator - none shown
started: Recently noticed, unclear when it started

## Eliminated

- hypothesis: checkForUpgrade() is never called
  evidence: Previous fix confirmed that checkForUpgrade() is now called in startProxy() (line 941-944). QuotaViewModel calls this after proxy starts.
  timestamp: 2026-01-20T00:01:30Z

- hypothesis: GitHub API doesn't return digest field
  evidence: Verified via curl that GitHub API for CLIProxyAPIPlus releases returns digest field with sha256: prefix for all assets
  timestamp: 2026-01-20T00:01:45Z

## Evidence

- timestamp: 2026-01-20T00:00:30Z
  checked: CLIProxyManager.checkForUpgrade() method (lines 1255-1327)
  found: Method exists and is called from startProxy(). It tries proxy API first, falls back to GitHub. Sets upgradeAvailable = true if newer version found.
  implication: The mechanism is in place. Need to trace where it might silently fail.

- timestamp: 2026-01-20T00:01:00Z
  checked: SettingsScreen.swift upgrade UI display
  found: UI correctly checks `proxyManager.upgradeAvailable` and `proxyManager.availableUpgrade` (lines 1048, 2111, 2428). Shows "Update Available" banner when true.
  implication: UI is wired correctly. Issue is in the detection logic, not display.

- timestamp: 2026-01-20T00:01:15Z
  checked: ProxyVersionInfo(from:asset:) initializer (lines 82-92)
  found: Returns nil if asset.sha256Checksum is nil or empty. sha256Checksum is extracted from asset.digest field only if it starts with "sha256:"
  implication: If GitHub asset doesn't have digest, ProxyVersionInfo returns nil, and upgradeAvailable stays false.

- timestamp: 2026-01-20T00:01:30Z
  checked: checkForUpgrade() error handling (lines 1308-1322)
  found: Multiple places where upgradeAvailable is set to false without logging: line 1303-1305 (no compatible asset), line 1309-1312 (ProxyVersionInfo is nil), line 1319-1322 (catch block)
  implication: Errors are silently swallowed. No way to diagnose why upgrade check failed.

- timestamp: 2026-01-20T00:01:45Z
  checked: GitHub API response for CLIProxyAPIPlus
  found: All assets DO have digest field with sha256: prefix. Example: "sha256:48b67b464fe038fa52210dc30bb0efdaa3a61a5082b7633be8f335b1e8c97a1b"
  implication: GitHub side looks correct. Issue might be in JSON decoding or version comparison.

## Resolution

root_cause:
fix:
verification:
files_changed: []
