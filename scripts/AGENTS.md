# Build & Release Scripts

11 bash scripts for building, packaging, notarizing, and releasing Quotio.

## Quick Reference

| Command | Purpose |
|---------|---------|
| `./scripts/build.sh` | Build release archive |
| `./scripts/package.sh` | Create ZIP + DMG |
| `./scripts/notarize.sh` | Apple notarization |
| `./scripts/release.sh` | Full release pipeline |
| `./scripts/quick-release.sh` | Interactive release helper |
| `./scripts/bump-version.sh` | Version management |

## Build Pipeline

```
build.sh → package.sh → notarize.sh → generate-appcast.sh
    ↓          ↓            ↓               ↓
 .xcarchive   ZIP+DMG    Stapled        appcast.xml
```

## Scripts

### build.sh
Creates Xcode archive with ad-hoc signing.
```bash
./scripts/build.sh
# Output: build/Quotio.app, build/Quotio.xcarchive
```

### package.sh
Creates distributable packages.
```bash
./scripts/package.sh
# Output: build/Quotio.zip, build/Quotio.dmg
```
- Uses `ditto` for ZIP (preserves attributes)
- Uses `create-dmg` for DMG with custom layout

### notarize.sh
Submits to Apple for notarization.
```bash
./scripts/notarize.sh
# Requires: APPLE_ID, TEAM_ID, APP_PASSWORD env vars
```
- Graceful skip if credentials missing
- Waits for approval, staples ticket

### release.sh
Full automated release.
```bash
./scripts/release.sh [version]
# Runs: bump → build → package → notarize → appcast
```

### quick-release.sh
Interactive release with prompts.
```bash
./scripts/quick-release.sh
# Prompts for version, confirms each step
```

### bump-version.sh
Updates version in Xcode project.
```bash
./scripts/bump-version.sh 1.2.3
# Updates: MARKETING_VERSION, CURRENT_PROJECT_VERSION
```

### generate-appcast.sh / generate-appcast-ci.sh
Generates Sparkle update manifest.
```bash
./scripts/generate-appcast.sh
# Output: appcast.xml with EdDSA signatures
```
- CI version merges prerelease with stable
- Downloads Sparkle tools if missing

### update-changelog.sh
Moves unreleased entries to versioned section.
```bash
./scripts/update-changelog.sh 1.2.3
```

### config.sh
Shared utilities (sourced by other scripts).
- Colorized output functions
- Progress spinners
- Timing utilities
- Error handling

## CI/CD (GitHub Actions)

### release.yml
Triggered by: `v*` tag push or manual dispatch.
```yaml
# Runs on: macOS 15, Xcode 26.1
# Artifacts: DMG, ZIP, appcast.xml → GitHub Releases
```

### changelog-unreleased.yml
Auto-updates CHANGELOG.md from conventional commits on master.

## Environment Variables

| Variable | Required For | Purpose |
|----------|--------------|---------|
| `APPLE_ID` | notarize.sh | Apple Developer email |
| `TEAM_ID` | notarize.sh | Apple Team ID |
| `APP_PASSWORD` | notarize.sh | App-specific password |
| `SPARKLE_KEY` | appcast | EdDSA private key path |

## Conventions

- All scripts use `set -e` (exit on error)
- Source `config.sh` for shared utilities
- Use colored output for visibility
- Measure and report execution time
- Support both local and CI execution
