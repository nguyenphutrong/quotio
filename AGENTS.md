# AGENTS.md

## Project

Quotio is a native macOS menu bar and window app for operating CLIProxyAPI. It manages
the local proxy lifecycle, provider OAuth accounts, quota monitoring, CLI agent
configuration, tunnels, updates, and optional telemetry.

- Swift 6 and SwiftUI, with targeted AppKit integration
- Minimum deployment target: macOS 14.0
- Xcode project: `Quotio.xcodeproj`; shared scheme: `Quotio`
- Targets: `Quotio` (application) and `QuotioTests` (executable integration tests)
- Core package: `Packages/QuotioCore` with four source and four test targets
- Dependency manager: Swift Package Manager through the local package and Xcode project
- Packages: Sparkle 2.8.1 and PostHog 3.64.1
- No CocoaPods, Carthage, Fastlane, root Swift package, or UI-test target

The app uses Clean Architecture module boundaries with pragmatic MVVM in Presentation.
`QuotioDomain` owns values and rules, `QuotioApplication` owns use cases and ports,
`QuotioInfrastructure` owns side effects and SDK adapters, and `QuotioPresentation`
owns SwiftUI/AppKit views and observable screen state. The executable composes the
production graph and owns lifecycle only.

## Project Map

- `Packages/QuotioCore/Sources/QuotioDomain/`: entities, value types, settings values,
  and pure policies.
- `Packages/QuotioCore/Sources/QuotioApplication/`: use cases, feature controllers,
  and side-effect ports.
- `Packages/QuotioCore/Sources/QuotioInfrastructure/`: HTTP, filesystem, process,
  Keychain, SQLite, Sparkle, PostHog, OAuth, provider, proxy, agent, and tunnel adapters.
- `Packages/QuotioCore/Sources/QuotioPresentation/`: SwiftUI/AppKit views, observable
  screen models, settings managers, menu bar UI, and localization helpers.
- `Packages/QuotioCore/Tests/`: unit and regression tests, split by owning module.
- `Quotio/QuotioApp.swift`: SwiftUI scene entry point.
- `Quotio/App/`: `CompositionRoot`, `AppRuntime`, `AppDelegate`, and app-only adapters.
- `Quotio/Assets.xcassets`: app icon, accent color, provider art, and menu bar assets.
- `Quotio/Localizable.xcstrings`: String Catalog for `en`, `fr`, `vi`, and `zh-Hans`.
- `Quotio/Info.plist`, `Quotio/Quotio.entitlements`: app metadata and entitlements.
- `QuotioTests/`: executable dependency-graph, lifecycle, identity, and bundle tests.
- `Config/`: Debug/Release xcconfig files and the template for local overrides.
- `scripts/`: local build/run helpers and release packaging scripts.
- `.github/workflows/release.yml`: tag/manual release pipeline.

The Xcode groups and local package use filesystem synchronization. Place new files in
the owning module or test target; manual edits to `project.pbxproj` are normally
unnecessary.

## Build, Test, and Run

Run commands from the repository root. These commands have been executed successfully
in this repository.

Build the Debug app:

```bash
xcodebuild -project Quotio.xcodeproj -scheme Quotio -configuration Debug -destination 'platform=macOS' build
```

Run all package tests and architecture checks:

```bash
swift test --package-path Packages/QuotioCore
./scripts/check_architecture.sh
```

Run the complete unit-test target:

```bash
xcodebuild -project Quotio.xcodeproj -scheme Quotio -configuration Debug -destination 'platform=macOS' test
```

Run one executable integration test class (replace the class name as needed):

```bash
xcodebuild -project Quotio.xcodeproj -scheme Quotio -configuration Debug -destination 'platform=macOS' -only-testing:QuotioTests/AppRuntimeTests test
```

Build, terminate any running Quotio instance, launch the new Debug app, and verify that
the process remains running:

```bash
./scripts/build_and_run.sh --verify
```

The run script leaves Quotio running and writes derived data under
`build/DebugDerivedData`. Always pass `--package-path Packages/QuotioCore` to SwiftPM;
the repository root is not a Swift package.

## Architecture and Coding Conventions

- Follow the existing naming scheme: `*Screen`, `*ViewModel`, `*Service`, `*Manager`,
  and provider-specific `*QuotaFetcher`. Use UpperCamelCase for types and lowerCamelCase
  for members.
- Keep one primary type per file and place it in the directory that owns its role.
  Extract a component or service only when it has a coherent responsibility.
- Keep Domain independent, Application dependent only on Domain, Infrastructure
  dependent on Application and Domain, and Presentation dependent on Application and
  Domain. Only `CompositionRoot` may construct concrete Infrastructure adapters.
- Do not add first-party singleton services. Inject long-lived dependencies from the
  composition root and pass platform behavior through Application ports.
- Use the existing Observation flow: `@Observable` models/view models, `@Environment`
  for shared dependencies, `@State` for view-owned state, and `@Bindable` when bindings
  to an observable object are required.
- Keep networking, persistence, OAuth, process management, Keychain, and SQLite out of
  Presentation. Views render state and forward intent; Application coordinates behavior;
  Infrastructure performs side effects.
- UI-facing mutable state belongs on `@MainActor`. Use `actor` for mutable asynchronous
  services and make values crossing isolation boundaries `Sendable` where appropriate.
- Prefer the codebase's async/await and `Task` patterns. NotificationCenter and limited
  GCD/AppKit interop are appropriate for lifecycle and menu bar integration; do not add
  Combine solely to implement a flow already expressible with Observation and concurrency.
- Model recoverable failures as typed semantic errors in Domain/Application and map them
  to localized user-presentable copy in Presentation. Infrastructure may retain sanitized
  technical context for logs. Reserve `try?` or ignored failures for explicitly
  best-effort behavior; do not hide failures on critical paths.
- Use the layer-owned logging ports/adapters instead of `print`. Keep sensitive values
  out of every log; executable lifecycle warnings use the app-only `Log` helper.
- There is no SwiftLint or SwiftFormat configuration. Match the surrounding Swift and
  Xcode formatting and avoid unrelated reformatting.

## Testing

- Tests use XCTest. Put unit and regression coverage in the owning
  `Quotio{Domain,Application,Infrastructure,Presentation}Tests` target. Use
  `QuotioTests` only for executable composition, lifecycle, identity, and bundle behavior.
- Name test files and `XCTestCase` classes after the subject. Use `test...` methods that
  state the behavior or regression being protected.
- Use `async`, `throws`, and `@MainActor` where the production contract requires them.
  Prefer temporary directories and injected dependencies over real user configuration.
- For a bug fix, reproduce the failure with a focused regression test when practical,
  then run the owning package tests and the full Xcode test target.
- There is no UI-test target. For UI work, launch the app and inspect light and dark
  appearances. For provider, OAuth, proxy, tunnel, or menu bar work, manually exercise
  the affected flow in addition to unit tests.

## Resources and Localization

- Add image/color resources to `Quotio/Assets.xcassets`; do not introduce loose resource
  files without confirming how the synchronized target includes them.
- Put all user-facing copy in `Quotio/Localizable.xcstrings`. Use `.localized()` in
  main-actor presentation code and `.localizedStatic()` from nonisolated model or enum
  properties. Follow existing `String(format:)` patterns for substitutions.
- Keep all supported locales aligned when adding or changing a localization key.
- Machine-specific values belong in gitignored `Config/Local.xcconfig`, based on
  `Config/Local.xcconfig.example`; never commit local signing or secret values.

## Project Gotchas

- `ProxyEndpoint.managementURL` must address CLIProxyAPI directly at
  `http://127.0.0.1:<port>`, even when the proxy binds to `0.0.0.0`. Management access is
  local-only; do not add remote bridge or fallback paths.
- Preserve `MacOSProxyProcessAdapter.killProcessOnPort` protection that refuses to
  terminate Quotio's own process.
- `FileProxyVersionRepository` stores versioned binaries behind a `current` symlink. Never
  remove the active version during cleanup.
- Agent configuration changes must preserve user-owned keys/content and create
  collision-safe timestamped backups without overwriting an existing backup.
- Treat auth and token files as hostile input: validate names and contents, use atomic
  private writes, and never follow a symlink destination.
- Never log or commit tokens, authorization headers, OAuth codes, cookies, API keys,
  local configuration, or other credentials.
- Essential initialization must work during login/headless launch when no window or
  view task is created. Keep required startup work in the app lifecycle/composition path.
- The app sandbox is intentionally disabled because Quotio manages local processes and
  CLI configuration. Do not enable it without auditing every filesystem/process flow.
- Guard APIs newer than macOS 14 with availability checks.
- Build port labels as `Text("localhost:" + String(port))`, not interpolated numeric
  `Text`, to avoid locale-aware number formatting.

## CI, Commits, and Pull Requests

- `.github/workflows/ci.yml` runs package tests, architecture checks, Xcode tests, and a
  Debug build. `.github/workflows/release.yml` handles `v*` tags and manual dispatch to
  build release artifacts, optionally sign/notarize them, publish the GitHub release and
  appcast, and dispatch the Homebrew tap update. Local build and test results are still
  required before review.
- Keep commits atomic and limited to one logical change.
- Follow the repository's Conventional Commit history, for example `fix(proxy): ...`,
  `feat(settings): ...`, `test: ...`, or `docs: ...`. Mark breaking changes explicitly.
- Before committing, inspect the worktree, unstaged diff, and staged diff. Stage only
  task-owned files and check for secrets and generated build output.
- Pull requests should state the behavior change, validation performed, and manual
  checks required. Include screenshots for visible UI changes and call out release,
  signing, entitlement, or migration impact.
