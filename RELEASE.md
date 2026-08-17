# Quotio Release Guide

## Automated Release

Use the GitHub **Release** workflow. It can be triggered from the Actions page with a version such as `1.2.3` or `1.2.3-beta-1`.

The workflow:

1. Updates `CHANGELOG.md` and the Xcode version.
2. When Apple credentials are configured, imports the Developer ID Application certificate into a temporary keychain.
3. When signing is enabled, signs nested code and the app with Hardened Runtime, notarizes the app, and staples the ticket.
4. Creates the ZIP and DMG; signed builds also sign, notarize, and staple the DMG.
5. Signs the final ZIP with Sparkle and creates the appcast.
6. Creates the tag and GitHub Release.
7. Commits the version and changelog changes back to the source branch.
8. Updates the Homebrew tap for stable releases.

GitHub Actions reads release credentials only from repository secrets:

| Name | Purpose |
|------|---------|
| `DEVELOPER_ID_CERTIFICATE_BASE64` | Base64-encoded Developer ID Application certificate and private key (`.p12`) |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12` |
| `APP_STORE_CONNECT_API_KEY_BASE64` | Base64-encoded App Store Connect API private key (`.p8`) |
| `APP_STORE_CONNECT_KEY_ID` | App Store Connect API key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | App Store Connect API issuer ID |
| `SPARKLE_PRIVATE_KEY` | Sparkle EdDSA signing key |
| `POSTHOG_PROJECT_TOKEN` | Optional PostHog project token embedded at build time |
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

## Local Artifacts

Build the current project version without changing source files:

```bash
./scripts/build_dmg.sh
```

Artifacts are written to `build/release/`:

- `Quotio-<version>.dmg`
- `Quotio-<version>.zip`

Install `create-dmg` for the custom DMG layout; otherwise the script falls back to `hdiutil`:

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

`SIGNING_IDENTITY` defaults to `Developer ID Application`; set it to the identity's SHA-1 hash if multiple Developer ID certificates are installed. `--version` modifies `CHANGELOG.md` and `Quotio.xcodeproj/project.pbxproj`. `--generate-appcast` creates `build/release/appcast.xml`; the script does not create a tag, push, or publish a GitHub Release.

Pre-release versions containing `alpha`, `beta`, or `rc` are added to the Sparkle beta channel.

## Verification

After a release:

- Download and open the DMG on a Mac that has not built Quotio locally.
- Confirm Gatekeeper opens Quotio without an `xattr` command or unsigned-app warning.
- Confirm `spctl --assess --type execute --verbose=2 /Applications/Quotio.app` reports `accepted` and `source=Notarized Developer ID`.
- Confirm the ZIP and `appcast.xml` are attached to the GitHub Release.
- Check stable and beta update channels as applicable.
