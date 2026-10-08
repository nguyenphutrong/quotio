# Scripts

Quotio has two self-contained script entrypoints:

- `build_and_run.sh`: build Debug, stop any running Quotio process, and launch the fresh app. Optional flags: `--debug`, `--logs`, `--telemetry`, `--verify`.
- `build_dmg.sh`: build a universal CLI helper before the Release archive, verify both architectures, and create ZIP and DMG artifacts without Finder automation. Pass `--distribution` to require Developer ID signing, notarization, stapling, and Gatekeeper validation.

`build_and_run.sh` respects the Xcode signing configuration. To sign local Debug builds with an Apple Development certificate, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set `DEVELOPMENT_TEAM` to your Apple team ID.

For a local release build, run from `apps/macos/`:

```bash
./scripts/build_dmg.sh
```

When the complete Apple credential set is present, the release workflow enables distribution mode to notarize the artifacts. Without those secrets it builds ad-hoc artifacts, so forks do not need the upstream signing credentials. A partially configured credential set fails instead of silently publishing unsigned artifacts.

Run the distribution path locally with:

```bash
NOTARYTOOL_KEYCHAIN_PROFILE=quotio-notarization \
SPARKLE_PRIVATE_KEY=... \
  ./scripts/build_dmg.sh --version 1.2.3 --distribution --generate-appcast
```

`SIGNING_IDENTITY` defaults to `Developer ID Application`. Set it to the certificate's SHA-1 hash when more than one matching identity is installed. See `RELEASE.md` for credential setup.

If `asc` already has App Store Connect credentials in the System Keychain, pass `--notarization-provider asc` to use them without a notarytool profile or private-key export. Set `ASC_PROFILE` to select a stored profile. The default remains `notarytool`, matching CI.

Prerelease versions build `Quotio Beta.app` with bundle identifier `app.bytrong.quotio.beta`. Install it beside `Quotio.app`; it uses separate Quotio-owned state and its own Sparkle feed. `--generate-appcast` writes `appcast-beta.xml` for prereleases. See [the release guide](../RELEASE.md#independent-beta-releases) for isolation boundaries.
