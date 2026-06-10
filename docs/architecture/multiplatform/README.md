# Native Multiplatform Architecture

This directory records the migration decisions for the macOS + Windows
architecture. The implementation source of truth remains the current Swift app
on `dev`; these ADRs define the boundaries for the staged migration.

## Demo Frontend Pin

Frontend source reference:
`/Volumes/Avocado/code/nguyenphutrong/quotio-go-demo`

Pinned tracked commit:
`351a839646114f39479d4c534796019aea757236`

The demo worktree was dirty when the pin was recorded, so migration work must
copy files from the pinned commit, not from the live working tree.

## Shared UI Development

The shared React desktop UI lives in `apps/desktop-ui` and is embedded by the
macOS `SharedDesktopUIScreen` or the Windows preview WebView2 host. The current
production macOS SwiftUI screens remain authoritative unless the host enables a
shared route flag.

For macOS development:

```bash
bun --cwd apps/desktop-ui dev
QUOTIO_DESKTOP_UI_DEV_SERVER=http://localhost:5173 open Quotio.xcodeproj
```

`QUOTIO_DESKTOP_UI_DEV_SERVER` automatically exposes the shared UI entry in
Debug builds. To test the bundled web assets instead, run the normal desktop UI
build first and launch the app with:

```bash
bun --cwd apps/desktop-ui build
QUOTIO_ENABLE_SHARED_UI=1 open Quotio.xcodeproj
```

For release-candidate cutover testing, the shared UI can also be enabled with a
persisted macOS defaults flag and rolled back without rebuilding:

```bash
defaults write dev.quotio.desktop sharedDesktopUIEnabled -bool true
defaults write dev.quotio.desktop.beta sharedDesktopUIEnabled -bool true
```

Set `QUOTIO_DISABLE_SHARED_UI=1` at launch to force the native Swift screens even
when the persisted flag is enabled. Delete the defaults key to return to the
build default:

```bash
defaults delete dev.quotio.desktop sharedDesktopUIEnabled
defaults delete dev.quotio.desktop.beta sharedDesktopUIEnabled
```

For Windows preview development, build `apps/desktop-ui` before the host build,
or set `QUOTIO_DESKTOP_UI_DEV_SERVER` to the Vite server URL. The Windows host
currently advertises only preview-safe capabilities. Credential Manager-backed
bootstrap config, shared remote management credential editing, local redacted
crash-report capture with optional upload, Claude Code settings.json, and
Codex/Amp/Gemini/OpenCode/Factory Droid install/rollback are available. Native
onboarding and automatic configuration for future agent paths stay disabled
until their adapters are implemented and verified on Windows CI.

Current shared route scope:

- Enabled by default in host bootstrap: overview, providers, quota, usage,
  virtual models, models, API keys, logs, agents, settings, about.
- Implemented with Windows read-only capability gates: virtual models, models,
  API keys, logs.
- Diagnostics only: about.
- Partial: settings exposes native remote management credentials only; other
  settings controls remain hidden until their owners are implemented.

## ADRs

- [ADR 0001: Layer ownership](0001-layer-ownership.md)
- [ADR 0002: Process model](0002-process-model.md)
- [ADR 0003: IPC and host bridge](0003-ipc-and-host-bridge.md)
- [ADR 0004: Schema versioning](0004-schema-versioning.md)
- [ADR 0005: Demo frontend adoption](0005-demo-frontend-adoption.md)
- [ADR 0006: Cutover gap matrix](0006-cutover-gap-matrix.md)
