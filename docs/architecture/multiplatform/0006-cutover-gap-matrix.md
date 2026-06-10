# ADR 0006: Cutover Gap Matrix

## Status

Accepted for staged migration.

## Context

Plan 10 requires native integration, release, and cutover readiness across
macOS and Windows. The current macOS app already has production release plumbing
through Sparkle, notarization scripts, appcast generation, and GitHub release
automation. The Windows host is still a preview scaffold: it builds a native
WinUI/WebView2 shell and bridge with Credential Manager-backed bootstrap
configuration, shared remote credential editing, local crash-report capture with
an optional upload endpoint, native agent write adapters, and a Velopack
installer/update package path, but it does not yet have production signing or
production crash ingestion.

The cutover must preserve native feel without claiming production parity before
the Windows host can actually install, update, and preserve data correctly.

## Decision

Shared desktop screens remain feature-flagged until each surface has native host
parity and a rollback path. macOS can continue shipping through the existing
SwiftUI implementation while shared screens are adopted screen by screen.
Windows builds keep zipped preview artifacts for smoke testing and produce
Velopack installer artifacts for release-path validation. Production Windows
cutover still waits on signing, install/upgrade/uninstall verification, and
production write paths on Windows CI.

## Gap Matrix

| Area | macOS status | Windows status | Cutover gate |
| --- | --- | --- | --- |
| App shell | Production SwiftUI menu bar app | Preview WinUI shell | Windows tray, lifecycle, single-instance, window restore, and native dialogs verified |
| Shared UI host | Embedded WKWebView host with environment and defaults-based runtime route flags | WebView2 host with feature flags | Both hosts pass the same contract version and route gate matrix |
| Runtime process | Existing CLIProxyAPI lifecycle plus shared Rust foundation | Preview host can start, stop, restart, health-gate startup, report crashed child exits, write local diagnostics, and capture/upload redacted crash reports when an upload endpoint is configured; shared Rust foundation is not packaged into a production installer | No-zombie-process and recovery checks pass in CI and manual OS smoke tests before production packaging |
| Management API | Existing Swift management client plus shared bridge | Bridge can proxy management requests | Endpoint parity approved per screen before enabling routes |
| Settings | Native Swift settings remain authoritative | Credential Manager-backed bootstrap config plus shared remote management connection form for native `Quotio/ManagementBaseUrl` and `Quotio/ManagementKey` credentials; unsupported settings controls hidden | Credentials live in Keychain/Credential Manager and unsupported controls are hidden |
| Agents | Native macOS SwiftUI write path remains authoritative | Claude Code settings.json, Codex, Amp CLI settings files, Gemini PowerShell profile, OpenCode, and Factory Droid adapters support descriptor, detection, diff preview, install, backup, and rollback | Descriptor, detection, diff, install, backup, and rollback endpoints exist per OS |
| Updates | Sparkle/appcast release path exists | Velopack update metadata and native check bridge exist; update checks require a Velopack-installed build | Signed Windows updater path tested before production release |
| Packaging | Existing release path plus unsigned preview artifact workflow | Zipped preview artifact plus Velopack installer artifacts from CI and manual release workflow | Signing, uninstall, upgrade, and user-data preservation tested |
| Rollback | Keep old Swift screens behind `sharedDesktopUIEnabled` and `QUOTIO_DISABLE_SHARED_UI` route flags | Keep shared route flags disabled by default | One release window with runtime flag rollback before removing superseded code |

## Rollback Window

For the first production release that enables a shared screen by default:

- Keep the native Swift implementation available behind a host feature flag.
- Keep the route disabled by default on Windows unless the Windows adapter has
  passed the same acceptance checks.
- Do not remove superseded Swift services until one release cycle after the
  shared screen has shipped without launch-blocking regressions.
- Treat raw i18n keys, web-only dialogs, missing keyboard flow, and platform
  styling regressions as rollback blockers.

## Release Verification

Before production cutover:

- Run `bun run contracts:check`, `bun run typecheck`, `bun run build`, and
  `bun run format-and-lint`.
- Run `bun run windows:gates:check` before changing Windows preview route or
  capability defaults.
- Run `cargo test`.
- Run `xcodebuild -project Quotio.xcodeproj -scheme Quotio -configuration Debug build`.
- Run `xcodebuild -project Quotio.xcodeproj -scheme "Quotio Beta" -configuration Beta build`.
- Run the `macOS Preview Artifact` workflow and verify it uploads unsigned
  ZIP/DMG artifacts without appcast or notarization steps.
- Run `dotnet build apps/windows-host/Quotio.Windows.csproj --configuration
  Release` on Windows CI.
- Run `dotnet run --project apps/windows-host-smoke/Quotio.WindowsSmoke.csproj
  --configuration Release` on Windows CI.
- Verify the Windows preview artifact is uploaded from CI, and verify the zip
  itself contains `desktop-ui/index.html` plus the Windows host executable.
- Verify the Windows installer artifact is uploaded from CI, and verify it
  contains a setup executable plus `releases.stable.json`.
- For public smoke testing, run the `Windows Preview Release` workflow with a
  `windows-preview-*` tag and verify the prerelease asset is uploaded.
- For installer smoke testing, run the `Windows Installer Release` workflow with
  a `windows-v*` tag and verify the release includes Velopack setup and update
  metadata assets.
- Manually verify light/dark mode, keyboard navigation, multiple monitors,
  sleep/restart recovery, offline behavior, and no stuck child processes on
  both operating systems before enabling route flags by default.
