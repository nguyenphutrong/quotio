# AGENTS.md

## Repository

Quotio is a monorepo with independent product entry points:

- `apps/macos/`: native macOS app. Follow `apps/macos/AGENTS.md`.
- `apps/ios/`: native iPhone companion and widgets. Follow `apps/ios/AGENTS.md`.
- `apps/cli/`: Rust CLI. Follow its README and existing Cargo conventions.
- `Packages/QuotioCore/`: Swift package shared by the Apple app.
- `.github/workflows/`: repository-level CI and release automation.

Do not add empty iOS or Windows projects, a root Cargo workspace, or a task runner
until a real consumer requires one. Keep product-specific code and release assets
inside the owning app directory.

## Commands

Run commands from the repository root unless a project document says otherwise.

```bash
swift test --package-path Packages/QuotioCore
./apps/macos/scripts/check_architecture.sh
xcodebuild -project apps/macos/Quotio.xcodeproj -scheme Quotio -configuration Debug -destination 'platform=macOS' test
cargo test --manifest-path apps/cli/Cargo.toml --locked --all-features
```

Use `v*` tags for macOS releases, `cli-v*` tags for CLI releases and
`desktop-v*` tags for the Windows and Linux desktop app. Preserve both imported
histories; never rewrite shared history or reuse one product's tag namespace for
another.
