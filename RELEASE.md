# Quotio Release Guide

## Quick Start (Recommended)

### Option 1: Push Tag (Automated via GitHub Actions)
```bash
# Update CHANGELOG.md (optional - will auto-update if missing)
# Then push a tag to trigger automatic release
git tag v0.5.0
git push origin v0.5.0
```

GitHub Actions will automatically:
1. Build the app
2. Create DMG and ZIP
3. Sign appcast with Sparkle
4. Create GitHub Release
5. Commit version bump back to master

### Option 2: Use Quick Release Script
```bash
./scripts/quick-release.sh 0.5.0           # Release 0.5.0
./scripts/quick-release.sh 0.5.0-beta-1    # Release beta
./scripts/quick-release.sh patch           # Bump patch and release
```

### Option 3: Manual Trigger from GitHub UI
1. Go to **Actions** → **Release** workflow
2. Click **Run workflow**
3. Enter version (e.g., `0.5.0`)
4. Click **Run workflow**

---

## Prerequisites (One-time Setup)

### 1. Add GitHub Secret
Go to **Settings** → **Secrets and variables** → **Actions** → **New repository secret**:

| Name | Value |
|------|-------|
| `SPARKLE_PRIVATE_KEY` | Your Sparkle EdDSA private key |

To export your Sparkle private key:
```bash
./.sparkle/bin/generate_keys -x /tmp/sparkle_key.txt
cat /tmp/sparkle_key.txt
rm /tmp/sparkle_key.txt
```

### 2. Install Local Dependencies (for local release)
```bash
brew install create-dmg
gh auth login
```

### 3. Generate Sparkle Keys (if not already done)
```bash
./.sparkle/bin/generate_keys
# Copy public key to Quotio/Info.plist → SUPublicEDKey
```

### 4. (Optional) Setup Notarization
```bash
xcrun notarytool store-credentials "quotio-notarization" \
    --apple-id "your@email.com" \
    --team-id "YOUR_TEAM_ID"
```

---

## Release Methods

### GitHub Actions (Recommended)

**Trigger by tag push:**
```bash
git tag v0.5.0
git push origin v0.5.0
```

**Trigger manually:**
- Go to Actions → Release → Run workflow

**What it does:**
1. Validates tag format
2. Updates CHANGELOG (auto-moves [Unreleased] if section missing)
3. Bumps version in project.pbxproj
4. Builds with Xcode 16
5. Creates ZIP and DMG packages
6. Signs appcast with Sparkle
7. Creates GitHub Release with assets
8. Commits version changes back to master

### Local Release (Fallback)

```bash
./scripts/release.sh patch   # 0.0.1 → 0.0.2
./scripts/release.sh minor   # 0.0.2 → 0.1.0
./scripts/release.sh major   # 0.1.0 → 1.0.0
./scripts/release.sh 1.2.3   # Set specific version
```

---

## Beta/Pre-release

```bash
./scripts/quick-release.sh 1.2.0-beta-1    # First beta
./scripts/quick-release.sh 1.2.0-beta-2    # Second beta
```

Beta releases:
- Are marked as pre-release on GitHub
- Include `<sparkle:channel>beta</sparkle:channel>` in appcast.xml
- Only visible to users who opt-in via Settings → Updates → Update Channel → Beta
- Use the beta app icon (yellow "BETA" banner)

---

## Scripts Reference

| Script | Purpose |
|--------|---------|
| `scripts/quick-release.sh` | Interactive release helper (tag + push) |
| `scripts/bump-version.sh` | Update version in project |
| `scripts/build.sh` | Build release archive |
| `scripts/package.sh` | Create ZIP and DMG |
| `scripts/update-changelog.sh` | Auto-update CHANGELOG |
| `scripts/generate-appcast.sh` | Generate appcast (local, uses Keychain) |
| `scripts/generate-appcast-ci.sh` | Generate appcast (CI, uses env var) |
| `scripts/notarize.sh` | Apple notarization (optional) |
| `scripts/release.sh` | Full local workflow |

---

## Version Naming

Follow [Semantic Versioning](https://semver.org/):
- **MAJOR** (1.0.0): Breaking changes
- **MINOR** (0.1.0): New features, backward compatible
- **PATCH** (0.0.1): Bug fixes
- **BETA** (1.0.0-beta-1): Pre-release versions for testing

---

## Troubleshooting

### GitHub Actions Failed
- Check **Actions** tab for error logs
- Verify `SPARKLE_PRIVATE_KEY` secret is set correctly
- Ensure tag format is `v*` (e.g., `v0.5.0`)

### "No Team Found in Archive"
→ Normal if no Apple Developer ID. Build script handles this automatically.

### Keychain Prompt During Local Appcast Generation
→ Click "Always Allow" to let Sparkle access signing keys.

### Gatekeeper Warning on First Launch
→ Expected for unsigned apps. Users can right-click → Open to bypass.

### Version Bump Not Committed
→ Check if `[skip ci]` is working. The workflow uses this to prevent infinite loops.

---

## Release Checklist

**Before release:**
- [ ] All changes committed and pushed
- [ ] CHANGELOG.md updated (or will auto-update)

**After tag push:**
- [ ] GitHub Actions workflow started
- [ ] Build succeeded
- [ ] GitHub Release created with DMG, ZIP, appcast.xml
- [ ] Version bump committed to master

**Verify:**
- [ ] Download and test the DMG
- [ ] Check auto-update works (Sparkle)
