# Contributing to Quotio

## Choose the target branch first

| Change | Base branch |
| --- | --- |
| Current macOS app (1.x), iPhone companion, Rust CLI, and shared host | `master` |
| Legacy macOS app (0.x), including its dashboard and CLI agent configuration | `v0.x` |

Reproduce the issue on the branch you intend to change. Include the app version,
target branch, and checks performed in your pull request. Follow that branch's
`AGENTS.md` and product documentation; the two macOS versions have different
runtime architectures and supported screens.

The old CLI agent setup and its built-in model catalog are not part of the 1.x
macOS runtime. Changes to that feature belong on `v0.x`. The catalog's fallback
when model discovery fails is separate from request-routing fallback; do not
assume a feature is supported just because old documentation mentions it.

## Contribute to the legacy macOS app

After cloning your fork, add the upstream repository if it is not already configured:

```bash
git remote add upstream https://github.com/nguyenphutrong/quotio.git
```

Create your work from the legacy branch, not from `master` or a release tag:

```bash
git fetch upstream
git switch -c fix/legacy-agent-models upstream/v0.x
```

Make and verify the change on that branch. From the repository root on a Mac:

```bash
swift test --package-path Packages/QuotioCore
./apps/macos/scripts/check_architecture.sh
xcodebuild -project apps/macos/Quotio.xcodeproj -scheme Quotio \
  -configuration Debug -destination 'platform=macOS' test
```

For agent configuration changes, also exercise the affected agent on the 0.x
app, including model-discovery failure if the change concerns the built-in catalog.
Preserve user-owned configuration and verify backup behavior.

Commit and push the feature branch to your fork, then open a pull request with
**base repository `nguyenphutrong/quotio`, base branch `v0.x`**. If using GitHub CLI:

```bash
gh pr create --repo nguyenphutrong/quotio --base v0.x
```

If you already started a PR from `master`, create a new branch from `upstream/v0.x`
and cherry-pick only the relevant fix commits. Verify again and open a replacement
PR targeting `v0.x`, linking the original. Merely changing the PR's base can bring
unrelated 1.x commits into the legacy branch.

## Contribute to current products

Start from `upstream/master` and target `master`. See the owning product's
[macOS guidance](apps/macos/AGENTS.md), [iOS guidance](apps/ios/AGENTS.md), or
[CLI documentation](apps/cli/README.md) for the relevant build and test commands.
Report checks you could not run; do not claim a macOS build passed from Linux.
