# CKota Release Guide

## Prerequisites (One-time Setup)

### 1. Install Dependencies
```bash
brew install create-dmg
gh auth login
```

### 2. Generate Sparkle Keys
```bash
# Run once to generate EdDSA keys (stored in Keychain)
./.sparkle/bin/generate_keys

# Copy the public key to CKota/Info.plist -> SUPublicEDKey
```

### 3. (Optional) Setup Notarization
```bash
# Only if you have Apple Developer ID
xcrun notarytool store-credentials "ckota-notarization" \
    --apple-id "your@email.com" \
    --team-id "YOUR_TEAM_ID"
```

---

## Release Process

### Quick Release (Recommended)
```bash
# Bump version and release
./scripts/release.sh patch   # 0.0.1 → 0.0.2
./scripts/release.sh minor   # 0.0.2 → 0.1.0
./scripts/release.sh major   # 0.1.0 → 1.0.0
./scripts/release.sh 1.2.3   # Set specific version
```

### Manual Step-by-Step

#### 1. Bump Version
```bash
./scripts/bump-version.sh patch
# or: ./scripts/bump-version.sh 1.2.3
```

#### 2. Build
```bash
./scripts/build.sh
```

#### 3. Package
```bash
./scripts/package.sh
```

#### 4. Generate Appcast (for auto-updates)
```bash
./scripts/generate-appcast.sh
# Note: May prompt for Keychain access
```

#### 5. Create GitHub Release
```bash
VERSION=$(grep -m1 "MARKETING_VERSION" CKota.xcodeproj/project.pbxproj | sed 's/.*= \(.*\);/\1/')

git tag -a "v${VERSION}" -m "Release ${VERSION}"
git push origin "v${VERSION}"

gh release create "v${VERSION}" \
    --title "CKota ${VERSION}" \
    --generate-notes \
    build/release/CKota-${VERSION}.zip \
    build/release/appcast.xml
```

---

## Scripts Reference

| Script | Purpose |
|--------|---------|
| `scripts/bump-version.sh` | Update version in project |
| `scripts/build.sh` | Build release archive |
| `scripts/package.sh` | Create ZIP (and DMG) |
| `scripts/generate-appcast.sh` | Generate Sparkle appcast.xml |
| `scripts/notarize.sh` | Apple notarization (optional) |
| `scripts/release.sh` | Full automated workflow |

---

## Version Naming

Follow [Semantic Versioning](https://semver.org/):
- **MAJOR** (1.0.0): Breaking changes
- **MINOR** (0.1.0): New features, backward compatible
- **PATCH** (0.0.1): Bug fixes

---

## Troubleshooting

### "No Team Found in Archive"
→ Normal if no Apple Developer ID. Build script handles this automatically.

### Keychain Prompt During Appcast Generation
→ Click "Always Allow" to let Sparkle access signing keys.

### Gatekeeper Warning on First Launch
→ Expected for unsigned apps. Users can right-click → Open to bypass.

---

## Release Checklist

- [ ] All changes committed
- [ ] Version bumped appropriately
- [ ] Build succeeds
- [ ] App launches and works correctly
- [ ] GitHub release created with assets
- [ ] (Optional) Appcast uploaded for auto-updates
