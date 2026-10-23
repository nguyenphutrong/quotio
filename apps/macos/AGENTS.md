# AGENTS.md

## Project

Quotio is a native macOS menu bar and window app for operating CLIProxyAPI. It manages
the local proxy lifecycle, provider OAuth accounts, quota monitoring, tunnels, and updates.
Legacy CLI agent configuration belongs to the `v0.x` branch, not `master`; see
`CONTRIBUTING.md` at the repository root.

- Swift 6 and SwiftUI, with targeted AppKit integration
- Minimum deployment target: macOS 14.0
- Xcode project: `apps/macos/Quotio.xcodeproj`; shared scheme: `Quotio`
- Targets: `Quotio` (application) and `QuotioTests` (executable integration tests)
- Core package: `Packages/QuotioCore` with four source and four test targets
- Dependency manager: Swift Package Manager through the local package and Xcode project
- Package: Sparkle 2.8.1
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
  Keychain, SQLite, Sparkle, OAuth, provider, proxy, agent, and tunnel adapters.
- `Packages/QuotioCore/Sources/QuotioPresentation/`: SwiftUI/AppKit views, observable
  screen models, settings managers, menu bar UI, and localization helpers.
- `Packages/QuotioCore/Tests/`: unit and regression tests, split by owning module.
- `apps/macos/Quotio/QuotioApp.swift`: SwiftUI scene entry point.
- `apps/macos/Quotio/App/`: `CompositionRoot`, `AppRuntime`, `AppDelegate`, and app-only adapters.
- `apps/macos/Quotio/Assets.xcassets`: app icon, accent color, provider art, and menu bar assets.
- `apps/macos/Quotio/Localizable.xcstrings`: String Catalog for `en`, `fr`, `vi`, and `zh-Hans`.
- `apps/macos/Quotio/Info.plist`, `apps/macos/Quotio/Quotio.entitlements`: app metadata and entitlements.
- `apps/macos/QuotioTests/`: executable dependency-graph, lifecycle, identity, and bundle tests.
- `apps/macos/Config/`: Debug/Release xcconfig files and the template for local overrides.
- `apps/macos/scripts/`: local build/run helpers and release packaging scripts.
- `.github/workflows/macos-release.yml`: tag/manual release pipeline.

The Xcode groups and local package use filesystem synchronization. Place new files in
the owning module or test target; manual edits to `project.pbxproj` are normally
unnecessary.

## Build, Test, and Run

Run commands from the repository root. Choose the check that exercises the changed
behavior; the command list is a reference, not a checklist for every task. Report
results from the current checkout rather than assuming a previous run still applies.

Build the Debug app:

```bash
xcodebuild -project apps/macos/Quotio.xcodeproj -scheme Quotio -configuration Debug -destination 'platform=macOS' build
```

For package-wide changes, run all package tests. Run architecture checks when module
boundaries, imports, or dependency composition change:

```bash
swift test --package-path Packages/QuotioCore
./apps/macos/scripts/check_architecture.sh
```

For executable-wide changes, run the complete integration-test target:

```bash
xcodebuild -project apps/macos/Quotio.xcodeproj -scheme Quotio -configuration Debug -destination 'platform=macOS' test
```

Run one executable integration test class (replace the class name as needed):

```bash
xcodebuild -project apps/macos/Quotio.xcodeproj -scheme Quotio -configuration Debug -destination 'platform=macOS' -only-testing:QuotioTests/AppRuntimeTests test
```

Build, terminate any running Quotio instance, launch the new Debug app, and verify that
the process remains running:

```bash
./apps/macos/scripts/build_and_run.sh --verify
```

The run script leaves Quotio running and writes derived data under
`apps/macos/build/DebugDerivedData`. Always pass `--package-path Packages/QuotioCore` to SwiftPM;
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
  then run the affected test or owning package target. Broaden to package-wide tests
  when shared contracts change, and run the relevant Xcode integration tests when
  executable composition, lifecycle, identity, or bundling is affected.
- Documentation-only changes need checks of referenced paths, commands, and the diff;
  they do not require an app build, test suite, or relaunch. Do not use
  `build_and_run.sh --verify` as a substitute for inspecting UI or affected behavior.
- There is no UI-test target. For UI work, launch the app and inspect light and dark
  appearances. For provider, OAuth, proxy, tunnel, or menu bar work, manually exercise
  the affected flow in addition to unit tests.

## Resources and Localization

- Add image/color resources to `apps/macos/Quotio/Assets.xcassets`; do not introduce loose resource
  files without confirming how the synchronized target includes them.
- Put all user-facing copy in `apps/macos/Quotio/Localizable.xcstrings`. Use `.localized()` in
  main-actor presentation code and `.localizedStatic()` from nonisolated model or enum
  properties. Follow existing `String(format:)` patterns for substitutions.
- Keep all supported locales aligned when adding or changing a localization key.
- Machine-specific values belong in gitignored `apps/macos/Config/Local.xcconfig`, based on
  `apps/macos/Config/Local.xcconfig.example`; never commit local signing or secret values.

## Project Gotchas

- `ProxyEndpoint.managementURL` must address CLIProxyAPI directly at
  `http://127.0.0.1:<port>`, even when the proxy binds to `0.0.0.0`. Management access is
  local-only; do not add remote bridge or fallback paths.
- Preserve `MacOSProxyProcessAdapter.killProcessOnPort` protection that refuses to
  terminate Quotio's own process.
- `FileProxyVersionRepository` stores versioned binaries behind a `current` symlink. Never
  remove the active version during cleanup.
- Treat auth and token files as hostile input: validate names and contents, use atomic
  private writes, and never follow a symlink destination.
- Never log or commit tokens, authorization headers, OAuth codes, cookies, API keys,
  local configuration, or other credentials.
- Essential initialization must work during login/headless launch when no window or
  view task is created. Keep required startup work in the app lifecycle/composition path.
- The app sandbox is intentionally disabled because Quotio manages local processes and
  CLI configuration. Do not enable it without auditing every filesystem/process flow.
- The CLI helper shares the standalone CLI's vault and config only when its signature satisfies the `dev.quotio.cli` Developer ID requirement (`QuotioCLIHelperSignature`); Debug and ad-hoc helpers keep the isolated namespace and must never be pointed at the shared vault.
- Guard APIs newer than macOS 14 with availability checks.
- Build port labels as `Text("localhost:" + String(port))`, not interpolated numeric
  `Text`, to avoid locale-aware number formatting.

## CI, Commits, and Pull Requests

- `.github/workflows/macos-ci.yml` runs package tests, architecture checks, Xcode tests, and a
  Debug build. `.github/workflows/macos-release.yml` handles `v*` tags and manual dispatch to
  build release artifacts, optionally sign/notarize them, publish the GitHub release and
  appcast, and dispatch the Homebrew tap update. Before review, report the relevant
  local checks from the Testing section and any checks that could not run.
- Keep the currently checked-out branch unless the user explicitly requests another.
  Do not switch to `main` or `master` merely to commit audit findings.
- Keep commits atomic and limited to one logical change.
- Follow the repository's Conventional Commit history, for example `fix(proxy): ...`,
  `feat(settings): ...`, `test: ...`, or `docs: ...`. Mark breaking changes explicitly.
- Before committing, inspect the worktree, unstaged diff, and staged diff. Stage only
  task-owned files and check for secrets and generated build output.
- Pull requests should state the behavior change, validation performed, and manual
  checks required. Include screenshots for visible UI changes and call out release,
  signing, entitlement, or migration impact.
