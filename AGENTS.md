# AGENTS.md

Quotio is a native macOS menu bar app for managing CLIProxyAPI: OAuth for multiple AI providers, quota visibility, proxy lifecycle, and CLI agent configuration.

## Stack

- Swift 6, SwiftUI, macOS 15+, Xcode 16+
- Sparkle via Swift Package Manager
- No dedicated automated test suite currently exists

## Where to look

- App entry: `Quotio/QuotioApp.swift`
- Models and enums: `Quotio/Models/`
- App state: `Quotio/ViewModels/`
- Business logic, proxy, API, OAuth, menu bar: `Quotio/Services/`
- SwiftUI screens and components: `Quotio/Views/`
- Build/release scripts: `scripts/`
- Build configuration: `Config/`

## Validate changes

Use this for normal code validation:

```bash
xcodebuild -project Quotio.xcodeproj -scheme Quotio -configuration Debug build
```

Only run release scripts when changing packaging, notarization, appcast, or release behavior:

```bash
./scripts/build.sh
./scripts/release.sh
```

For UI changes, also run the app manually and check light/dark mode. For provider, OAuth, proxy, or menu bar changes, manually verify the affected flow.

## Project rules

- Keep UI-facing mutable state on `@MainActor`; use `actor` for async services with mutable state.
- DTOs crossing concurrency boundaries should be `Sendable`.
- Use SwiftUI Observation patterns already present in the repo (`@Observable`, `@Environment`, `@Bindable`).
- Do not put networking, persistence, process management, or OAuth logic directly in SwiftUI views.
- User-facing strings should use the existing localization approach, not hardcoded view text.
- Do not log or commit tokens, authorization headers, OAuth codes, cookies, secrets, or local config.
- Treat user changes and untracked files as user-owned; never delete, clean, or overwrite them without explicit permission.

## Invariants

- `ProxyStorageManager`: never delete the current proxy version.
- `AgentConfigurationService`: never overwrite existing backups.
- `ProxyBridge`: target host must remain localhost.
- `CLIProxyManager`: base URL must point directly to CLIProxyAPI.
- Avoid `Text("localhost:\(port)")`; use `Text("localhost:" + String(port))` to prevent locale formatting.

## Git

- Never commit to `master`.
- Before committing, inspect `git status`, `git diff`, and `git diff --cached`.
- Check staged changes for secrets and generated build output.
- Prefer concise conventional commit messages.

Keep this file short and high-signal. Prefer pointers to source files over copied code or long directory listings.
