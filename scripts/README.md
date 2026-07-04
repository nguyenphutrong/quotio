# Scripts

Small entrypoints only. Keep shared constants and output helpers in `config.sh`.

## Build And Run

- `build_and_run.sh`: build Debug, stop any running Quotio process, and launch the fresh app. Optional flags: `--debug`, `--logs`, `--telemetry`, `--verify`.
- `debug.sh`: compatibility wrapper for `build_and_run.sh`; accepts the same flags.
- `verify.sh`: run the available local checks with a Debug macOS build and graceful skips for missing optional tools or test targets.

## Build And Package

- `build.sh`: create a Release archive, extract `Quotio.app`, verify the bundled proxy, and ad-hoc sign the app.
- `package.sh`: create release ZIP and DMG artifacts from `build/Quotio.app`.
- `notarize.sh`: optionally notarize and staple the built app when the configured notarytool keychain profile exists.
- `verify-bundled-proxy.sh`: verify the bundled `cli-proxy-api-plus` checksum against the app model source.
- `deploy-local.sh`: build, optionally notarize, and create local ZIP/DMG artifacts without tagging, pushing, or creating a GitHub release.

## Release

- `bump-version.sh`: update Xcode marketing/build versions.
- `update-changelog.sh`: move unreleased changelog content into a version section.
- `generate-appcast.sh`: generate a local Sparkle appcast using local Sparkle tools.
- `generate-appcast-ci.sh`: generate a CI appcast using `SPARKLE_PRIVATE_KEY`.
- `release.sh`: full local release workflow for build, optional notarization, packaging, local appcast, tag, and GitHub release.
