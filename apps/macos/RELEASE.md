# Quotio Release Guide

Run local commands in this guide from `apps/macos/`.

## Automated Release

Use the GitHub **macOS Release** workflow. It can be triggered from the Actions page with a version such as `1.2.3` or `1.2.3-beta-1`.

The workflow:

1. Runs core package, host client, architecture, and app integration checks.
2. Updates `CHANGELOG.md` and the Xcode version.
3. When Apple credentials are configured, imports the Developer ID Application certificate into a temporary keychain.
4. When signing is enabled, signs nested code and the app with Hardened Runtime, notarizes the app, and staples the ticket.
5. Creates the universal app, ZIP, and DMG; signed builds also sign, notarize, and staple the DMG.
6. Signs the final ZIP with Sparkle and creates the appcast: `appcast.xml` for stable releases, `appcast-beta.xml` for prereleases.
7. Creates the tag and GitHub Release, including the matching version section from `CHANGELOG.md` and GitHub's generated pull request summary.
8. Commits the version and changelog changes back to the source branch.
9. Updates the Homebrew tap for stable releases.

Populate the version's `CHANGELOG.md` section before publishing. The workflow rejects missing or empty release notes.

GitHub Actions reads release credentials only from repository secrets:

| Name | Purpose |
|------|---------|
| `DEVELOPER_ID_CERTIFICATE_BASE64` | Base64-encoded Developer ID Application certificate and private key (`.p12`) |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12` |
| `APP_STORE_CONNECT_API_KEY_BASE64` | Base64-encoded App Store Connect API private key (`.p8`) |
| `APP_STORE_CONNECT_KEY_ID` | App Store Connect API key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | App Store Connect API issuer ID |
| `SPARKLE_PRIVATE_KEY` | Sparkle EdDSA signing key for stable releases only |
| `TAP_TOKEN` | Dispatch the stable release to the Homebrew tap |

The five Apple signing secrets are an optional all-or-none group. When all five are absent, the workflow still builds the existing ad-hoc artifacts, which keeps forks usable without access to the upstream credentials. When any Apple signing secret is set, all five must be set so a partially configured release cannot silently fall back to ad-hoc signing.

Create a **Developer ID Application** certificate from the Apple Developer portal or Xcode, install it together with its private key, and export both from Keychain Access as a password-protected `.p12`. Create a team App Store Connect API key under **Users and Access > Integrations** and download its `.p8` file. The private key can only be downloaded once.

Encode the two files before adding them as GitHub Actions secrets:

```bash
base64 -i DeveloperIDApplication.p12 | pbcopy
base64 -i AuthKey_KEY_ID.p8 | pbcopy
```

Do not commit either file. The workflow validates all credentials before building and deletes its temporary keychain and key files after the build.

The production bundle identifier is `app.bytrong.quotio`. The first signed release using this identifier migrates preferences and Quotio-owned Keychain items from `dev.quotio.desktop`. Because both the bundle identifier and signing requirement change, existing ad-hoc installations may need to install that release manually once; later Sparkle updates retain the stable Developer ID identity. Users may also need to re-enable Launch at Login after this one-time transition.

## Independent Beta Releases

Versions matching `X.Y.Z-alpha-N`, `X.Y.Z-beta-N`, or `X.Y.Z-rc-N` (also accepting `.N` suffixes) build a separate beta app. Choose an unused tag.

| Identity or resource | Stable | Prerelease |
|----------------------|--------|------------|
| App bundle | `Quotio.app` | `Quotio Beta.app` |
| Bundle identifier | `app.bytrong.quotio` | `app.bytrong.quotio.beta` |
| URL scheme | `quotio` | `quotio-beta` |
| Proxy configuration and binaries | `~/Library/Application Support/Quotio/` | `~/Library/Application Support/app.bytrong.quotio.beta/` |
| Proxy auth files | `~/.cli-proxy-api/` | `~/Library/Application Support/app.bytrong.quotio.beta/auth/` |
| Default proxy port | `8317` | `8318` |
| App updates | Sparkle | Manual download and installation |

App preferences, Quotio-owned Keychain services, helper data, helper vault namespace, and Antigravity profile backups are also scoped to the app identity. Beta does not import legacy production accounts or preferences. Beta only stops proxy processes it owns; an occupied port is an error, not permission to terminate another instance.

Install `Quotio Beta.app` beside the stable app. Prereleases do not modify the stable appcast or update the Homebrew tap. They publish `appcast-beta.xml` to the rolling `macos-beta-appcast` GitHub release, which stays marked as a prerelease so `releases/latest` keeps resolving to the stable appcast. The beta bundle's `SUFeedURL` points at that file, so Quotio Beta updates itself through Sparkle to newer betas only. Betas published before this change have no feed; install the first auto-updating beta manually.

This separates Quotio-owned state, not external applications. Native provider login stores remain shared external resources, and explicitly switching an external login or configuring a CLI agent can affect that tool outside Quotio. Avoid those actions while testing if the production login/configuration must remain unchanged.

## Local Artifacts

Build the current project version without changing source files:

```bash
./scripts/build_dmg.sh
```

Artifacts are written to `build/release/`:

- `Quotio-<version>.dmg`
- `Quotio-<version>.zip`

Install `create-dmg` for an Applications shortcut in the DMG; otherwise the script uses `hdiutil`. Packaging skips Finder AppleScript so it can run unattended:

```bash
brew install create-dmg
```

## Local Signed Release

Install the Developer ID Application certificate and private key in Keychain, then store the notarization API credentials once:

```bash
xcrun notarytool store-credentials quotio-notarization \
  --key /path/to/AuthKey_KEY_ID.p8 \
  --key-id KEY_ID \
  --issuer ISSUER_ID
```

Run the same signed and notarized packaging path as CI:

```bash
NOTARYTOOL_KEYCHAIN_PROFILE=quotio-notarization \
SPARKLE_PRIVATE_KEY=... \
  ./scripts/build_dmg.sh --version 1.2.3 --distribution --generate-appcast
```

`SIGNING_IDENTITY` defaults to `Developer ID Application`; set it to the identity's SHA-1 hash if multiple Developer ID certificates are installed. `--version` modifies `CHANGELOG.md` and `Quotio.xcodeproj/project.pbxproj`. `--generate-appcast` creates `build/release/appcast.xml` for stable versions and `build/release/appcast-beta.xml` for prereleases. The script does not create a tag, push, or publish a GitHub Release.

For an independent signed beta, run `NOTARYTOOL_KEYCHAIN_PROFILE=quotio-notarization SPARKLE_PRIVATE_KEY=... ./scripts/build_dmg.sh --version 1.0.0-beta.1 --distribution --generate-appcast`. Omit `--generate-appcast` and the key when you do not publish the beta feed. Local builds without `--distribution` are ad-hoc smoke artifacts, not notarized distribution builds.

If App Store Connect credentials are already stored in the System Keychain by `asc`, use them directly without exporting the private key or creating a notarytool profile:

```bash
ASC_PROFILE="your-profile" \
  ./scripts/build_dmg.sh --version 1.0.0-beta.1 --distribution --notarization-provider asc
```

`--notarization-provider` accepts `notarytool` (the default, also used by CI) or `asc`. The ASC path uses the CLI's existing authentication resolution; `ASC_PROFILE` selects a stored profile without changing its default. Both paths submit the app and DMG, staple their tickets, and require Gatekeeper acceptance before succeeding.

## Verification

After a release:

- Download and open the DMG on a Mac that has not built Quotio locally.
- Confirm Gatekeeper opens the app without an `xattr` command or unsigned-app warning.
- Confirm `spctl --assess --type execute --verbose=2 /Applications/Quotio.app` reports `accepted` and `source=Notarized Developer ID`; use `/Applications/Quotio Beta.app` for a beta.
- Confirm the ZIP and DMG are attached to the GitHub Release. Stable releases also attach `appcast.xml`; prereleases must not, and instead update `appcast-beta.xml` on the `macos-beta-appcast` release.
- Launch beta alongside stable and check independent preferences, helper paths, and proxy ports. Quit beta and confirm stable still runs with its configuration unchanged.
- Check stable and beta Sparkle updates separately. Each app must only offer versions from its own feed.
