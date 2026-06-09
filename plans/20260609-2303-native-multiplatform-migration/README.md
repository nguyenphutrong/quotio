# Quotio Native Multiplatform Migration Roadmap

## Goal

Port Quotio from the current native macOS SwiftUI application to macOS and
Windows while preserving native windowing, menu bar/system tray behavior,
keyboard behavior, materials, notifications, updates, and lifecycle.

The target architecture is:

- macOS host: Swift + AppKit/SwiftUI + `WKWebView`
- Windows host: C# + WinUI 3 + Win32 + WebView2
- Shared application UI: React + TypeScript
- Shared platform-neutral runtime: Rust
- Managed service: CLIProxyAPI/cpa-plusplus
- Frontend foundation: adapted from
  `/Volumes/Avocado/code/nguyenphutrong/quotio-go-demo`

## Starting Point

- `dev` is the only implementation source of truth.
- The current Swift application is the behavioral reference during migration.
- `quotio-go-demo` is the frontend architecture, component, design-token, and
  reusable screen reference.
- The migration must not use or depend on `feature/tauri-port`.
- The current macOS app remains shippable until the final cutover.
- Node is not part of the initial architecture because Quotio has no plugin
  runtime that requires it.

## Architectural Rules

1. Native hosts own windows, menu bar/system tray, notifications, credentials,
   launch-at-login, updater, native dialogs, and OS lifecycle.
2. React owns shared main-window screens, navigation, and presentation state.
3. Rust owns platform-neutral runtime behavior, CLIProxyAPI supervision,
   management API access, normalized models, and shared configuration logic.
4. Platform-specific behavior is expressed through narrow host adapters.
5. IPC is asynchronous, versioned, typed from one schema, and observable.
6. Each migration plan must leave the current macOS release path working.
7. A Swift feature is removed only after its replacement passes parity checks.
8. Reuse the demo frontend before creating new React components or patterns.
9. Adapt web-specific behavior to desktop-native behavior instead of copying it
   unchanged.

## Frontend Reuse Policy

See [Demo frontend adoption matrix](demo-frontend-adoption-matrix.md) for the
source paths and adaptation rules.

The default frontend stack is inherited from `quotio-go-demo`:

- Bun workspaces + Turborepo
- React 19 + Vite
- TanStack Router, Query, and Form
- `@quotio/ui`
- shadcn `base-maia` + Base UI + Tailwind CSS v4 + CVA
- Remix Icon
- i18next
- Biome + Lefthook

Do not rebuild this foundation from scratch. Copy the tracked frontend baseline
from the demo at a pinned commit, then adapt it inside Quotio.

## Execution Order

| Order | Plan | Outcome |
|---|---|---|
| 00 | [Architecture decisions and risk spikes](00-architecture-decisions-and-risk-spikes.md) | Prove the riskiest boundaries before committing |
| 01 | [Workspace and contract foundation](01-workspace-and-contract-foundation.md) | Adopt demo frontend foundation and add core/schema/host projects |
| 02 | [Shared runtime process lifecycle](02-shared-runtime-process-lifecycle.md) | Rust manages CLIProxyAPI consistently |
| 03 | [Shared management API and models](03-shared-management-api-and-models.md) | Typed shared read/write management surface |
| 04 | [macOS hybrid host foundation](04-macos-hybrid-host-foundation.md) | Current macOS shell hosts one shared React screen |
| 05 | [Windows native host foundation](05-windows-native-host-foundation.md) | Preview Windows native shell with tray and shared screen |
| 06 | [Dashboard, quota, and providers](06-dashboard-quota-providers.md) | First useful cross-platform product slice |
| 07 | [Management screens](07-management-screens.md) | Models, fallback, API keys, logs, and usage parity |
| 08 | [Settings, modes, and onboarding](08-settings-modes-onboarding.md) | Cross-platform configuration and first-run flow |
| 09 | [Agents and platform adapters](09-agents-and-platform-adapters.md) | OS-specific agent discovery/configuration behind shared contracts |
| 10 | [Native integration, cutover, and release](10-native-integration-cutover-release.md) | Production-ready macOS and Windows releases |

## Merge Strategy

- Implement each plan on its own `feature/<plan-name>` branch from the latest
  `dev`.
- Prefer one reviewable PR per plan.
- Plans 02 and 03 may proceed in parallel after Plan 01.
- Plans 04 and 05 may proceed in parallel after Plans 01-03.
- Feature plans 06-09 require both host foundations to be functional.
- Do not delete current Swift screens or services before Plan 10.

## Global Verification Gates

Every plan must pass the checks relevant to its touched surfaces:

- Existing macOS build:
  `xcodebuild -project Quotio.xcodeproj -scheme Quotio -configuration Debug build`
- Rust core tests and platform builds.
- Shared TypeScript typecheck, lint, and production build.
- Demo-derived UI remains attributable to a pinned source commit and deviations
  are documented.
- Windows host build on Windows CI.
- Manual parity check against the current Swift implementation.
- No raw IPC message names or duplicated handwritten DTO definitions.

## Stop Conditions

Pause the migration and revisit the architecture if a spike demonstrates any of
these:

- The chosen typed binding approach cannot support Swift and C# reliably.
- The macOS hybrid host introduces visible launch flashes or breaks native menu
  behavior.
- WebView2 distribution or Windows packaging cannot meet the supported OS
  baseline.
- Shared UI cannot meet keyboard, accessibility, or perceived-performance
  requirements on both engines.
