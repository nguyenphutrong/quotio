# Prepare a macOS release

A successful local build is not a notarized release. Use this procedure after the
[deployment acceptance checks](operations.md#release-acceptance) pass. Do not store
certificate names, team IDs, account data or notarization credentials in Git.

## Build and collect notices

Start from a clean revision and run the checks in `VALIDATION.md`. Build on each
architecture you intend to distribute; this script produces a host binary, not a
universal binary.

```sh
scripts/build-signed.sh --release --locked --distribution
```

Distribution mode requires exactly one selected **Developer ID Application**
identity and uses a secure timestamp plus hardened runtime. It does not fall back
to an Apple Development identity. If selection is ambiguous, set
`QUOTIO_SIGNING_IDENTITY` locally to the intended identity. Timestamping requires
Apple network access even when Cargo dependencies are available offline.

Create a new staging directory outside Git. Copy `target/release/quotio` and the
project `LICENSE` into it. Generate dependency notices using the actual build
triple, for example:

```sh
python3 scripts/third-party-notices.py \
  --target aarch64-apple-darwin \
  --output /absolute/new-staging/THIRD-PARTY-NOTICES.md
```

The generator reads locked, locally installed dependency packages. It includes
normal/build dependencies and their available license/notice files, excludes
dev-only dependencies, refuses missing license text and never overwrites output.
Review the notices for the release; generation is not a legal compliance audit.

If a crates.io package omits its upstream license files, the generator uses reviewed texts in `distribution/licenses/<crate>-<version>/`. Supplements apply only to that exact crates.io package and version; other missing licenses still fail packaging. The `asn1-rs-impl` 0.2.0 supplement contains the upstream MIT and Apache texts from [commit a20e5f7319c896737ad0f2557037817b91ad854f](https://github.com/rusticata/asn1-rs/tree/a20e5f7319c896737ad0f2557037817b91ad854f), recorded in that crate's `.cargo_vcs_info.json`. The `tern-sdk` 0.1.0 package was published from a private workspace, so its supplement is the MIT text from the public SDK repository at [commit d3485ad6159470bd301ee3a1345617cf5c6ad10c](https://github.com/stencil-hq/tern-sdk/blob/d3485ad6159470bd301ee3a1345617cf5c6ad10c/LICENSE).

Use `x86_64-apple-darwin` only for an Intel build, and do not relabel an ARM binary.

## Verify and notarize

Verify the staged binary before archiving:

```sh
codesign --verify --strict /absolute/new-staging/quotio
file /absolute/new-staging/quotio
shasum -a 256 /absolute/new-staging/quotio
```

Create a ZIP containing the binary, project license and dependency notices. Submit
that ZIP with a notarization profile already configured in the local Keychain:

```sh
xcrun notarytool submit /absolute/quotio-release.zip \
  --keychain-profile YOUR_LOCAL_PROFILE --wait
```

Do not publish until the submission is accepted and the downloaded artifact has
been tested on a clean Mac. A raw executable or ZIP cannot carry a stapled ticket;
use an appropriate signed installer or disk image if offline Gatekeeper acceptance
is required. This repository does not currently produce that installer.

Record the revision, target, checksums, signing verification, notarization outcome
and clean-machine result. Test vault access across an upgrade with the same
signing identity. Keep the previous artifact for rollback. Publishing, uploading
and notarization are separate release actions; the build scripts perform none of
them automatically.

References: Apple's [notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
and [notarization troubleshooting](https://developer.apple.com/documentation/security/resolving-common-notarization-issues).
