# Build local desktop packages

Run these commands from the repository root. Use Python 3.11 or newer and the
Rust stable toolchain. The packager creates a new output directory and never
publishes a release, uploads a feed, or changes a tag.

## Package Linux or Windows

Build on the target OS. On Linux, install the development libraries listed in
`.github/workflows/desktop-release.yml` first.

```sh
python3 apps/desktop/scripts/package.py \
  --target x86_64-unknown-linux-gnu --output dist/linux
```

On Windows, use an MSVC Rust toolchain and run:

```sh
python apps/desktop/scripts/package.py --target x86_64-pc-windows-msvc --output dist/windows
```

Each directory contains the raw updater executable, a portable archive, and a
platform-specific SHA256 manifest. The archive includes the icon, license, and
installation notes. Linux also includes a desktop entry. To package an existing
release executable, add `--binary PATH`.

The Linux package targets x64 Ubuntu 24.04 or a compatible system with glibc
2.39 or newer. It needs Vulkan, a working GPU driver, X11 or Wayland,
fontconfig, FreeType, and xkbcommon. It is not an AppImage or a Flatpak.

The Windows x64 ZIP is portable, not an installer. It has no Authenticode
signature and may trigger SmartScreen. Ed25519 updater signatures do not
replace Authenticode signatures. The in-app updater needs write access beside
the executable.

## Package a universal macOS preview

Use a Mac with Xcode command-line tools and both Rust targets installed:

```sh
rustup target add aarch64-apple-darwin x86_64-apple-darwin
```

Obtain and verify Sparkle 2.8.1 separately. Pass its universal
`Sparkle.framework` directory explicitly. The packager does not download it.
Supply a public Ed25519 key whose private key can sign your update archives.
Do not put a private key in a command, repository, or log.

```sh
python3 apps/desktop/scripts/package.py \
  --target universal-apple-darwin --output dist/macos-preview \
  --sparkle-framework /path/to/Sparkle.framework \
  --feed-url https://example.invalid/preview-appcast.xml \
  --public-key "$SPARKLE_PUBLIC_KEY" --build-number 1 \
  --sign-identity 'Developer ID Application: YOUR IDENTITY'
```

Replace the example feed with your test feed before running the app. The
packager builds both architectures with a macOS 14.0 deployment target. It
checks both executable slices and all bundled Mach-O architectures, creates
the app and icon, signs nested components before the outer bundle, and creates
ZIP and DMG files.

Without `--sign-identity`, the app receives an ad-hoc signature for local
development. That build is not suitable for distribution or shared-vault
Keychain testing.

The default bundle is `app.bytrong.quotio.preview`, named
`Quotio Desktop Preview`, with the `quotio-gpui-preview` URL scheme. A preview
bundle ID does **not** isolate data. Developer ID builds use the
`dev.quotio.cli` code-signing identifier and can access the standalone CLI's
shared vault. Do not launch a preview against a real user's account data as a
synthetic test. Disposable-Keychain probes require the separate fail-closed
test hooks described in `specs/gpui-cutover/TECH.md`.

For a loopback HTTP test feed, use a bundle ID ending in `.preview` and add
`--allow-local-feed`. Other feeds must use HTTPS. Use `--update-channel beta`
to allow Sparkle's beta channel. The production beta bundle ID requires that
option. A future replacement of an installed Swift app must keep its bundle
ID and update channel and use a build number greater than the installed build.
Do not change production bundle IDs or feeds just to run this preview.

## Notarize an authorized test bundle

Only submit to Apple when authorized. Add either `--notary-profile PROFILE`
for an existing `notarytool` profile or `--notarize-asc` for an existing ASC
connection. Both require Developer ID signing. The packager submits the ZIP,
staples the app, recreates the ZIP, then submits and staples the DMG. It checks
the resulting tickets and Gatekeeper policy. A failure stops packaging.

Submission does not publish the package. Keep the returned submission IDs and
logs. Test a fresh extracted or Finder-copied app with quarantine intact.
Packaging checks do not prove that first launch or an update succeeds.

## Verify before distributing

For macOS, test Sparkle's whole-bundle update and relaunch with signed A and B
builds. Check automatic updates on and off, the beta channel, and rejection of
a bad update signature. Verify the copied app's signature, notarization ticket,
and Gatekeeper result. Run migration with disposable synthetic data and verify
that source data remains unchanged.

For Linux and Windows, extract the archive on a clean native system and run
the executable. Check dependencies, tray behavior, restart, and signed updates.
The release workflow builds portable archives but does not prove these runtime
behaviors. Manual dispatch of that workflow publishes a prerelease. Do not use
dispatch as a packaging-only test.

The macOS appcast still needs separately generated Sparkle archive signatures.
Linux and Windows release assets need the existing Ed25519 release-signing
step. SHA256 manifests alone do not authenticate an update.
