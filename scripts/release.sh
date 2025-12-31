#!/bin/bash
set -e

# =============================================================================
# Full Release Workflow
# Usage: ./release.sh [version] [--beta]
#   version: major, minor, patch, X.Y.Z, or X.Y.Z-beta-N (optional)
#   --beta: Mark as pre-release on GitHub (auto-detected for -beta- versions)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

VERSION_ARG="${1:-}"
BETA_FLAG="${2:-}"

IS_BETA=false
if [[ "$VERSION_ARG" == *"-beta-"* ]] || [[ "$BETA_FLAG" == "--beta" ]]; then
    IS_BETA=true
fi

# Check prerequisites
check_command xcodebuild
check_command xcrun
check_command gh

# Check if gh is authenticated
if ! gh auth status &>/dev/null; then
    log_error "GitHub CLI not authenticated. Run: gh auth login"
    exit 1
fi

# Bump version if specified
if [ -n "$VERSION_ARG" ]; then
    NEW_VERSION=$("${SCRIPT_DIR}/bump-version.sh" "$VERSION_ARG")
else
    NEW_VERSION=$(get_version)
fi

log_info "=========================================="
log_info "Starting release for ${PROJECT_NAME} v${NEW_VERSION}"
log_info "=========================================="

# Step 1: Build
log_step "Step 1/5: Building..."
"${SCRIPT_DIR}/build.sh"

# Step 2: Notarize (optional - will skip if not configured)
log_step "Step 2/5: Notarizing..."
"${SCRIPT_DIR}/notarize.sh" || log_warn "Notarization skipped or failed"

# Step 3: Package
log_step "Step 3/5: Packaging..."
"${SCRIPT_DIR}/package.sh"

# Step 4: Generate appcast
log_step "Step 4/5: Generating appcast..."
"${SCRIPT_DIR}/generate-appcast.sh"

# Step 5: Create GitHub release
log_step "Step 5/5: Creating GitHub release..."

TAG_NAME="v${NEW_VERSION}"
DMG_FILE="${RELEASE_DIR}/${PROJECT_NAME}-${NEW_VERSION}.dmg"
ZIP_FILE="${RELEASE_DIR}/${PROJECT_NAME}-${NEW_VERSION}.zip"

# Check if files exist
if [ ! -f "$DMG_FILE" ] && [ ! -f "$ZIP_FILE" ]; then
    log_error "No release files found"
    exit 1
fi

# Create git tag if not exists
if ! git tag -l | grep -q "^${TAG_NAME}$"; then
    log_info "Creating git tag: ${TAG_NAME}"
    git tag -a "$TAG_NAME" -m "Release ${NEW_VERSION}"
    git push origin "$TAG_NAME"
else
    log_warn "Tag ${TAG_NAME} already exists"
fi

# Prepare release files
RELEASE_FILES=""
[ -f "$DMG_FILE" ] && RELEASE_FILES="$RELEASE_FILES $DMG_FILE"
[ -f "$ZIP_FILE" ] && RELEASE_FILES="$RELEASE_FILES $ZIP_FILE"
[ -f "$APPCAST_PATH" ] && RELEASE_FILES="$RELEASE_FILES $APPCAST_PATH"

# Create GitHub release
log_info "Creating GitHub release..."

RELEASE_FLAGS=""
if [ "$IS_BETA" = true ]; then
    RELEASE_FLAGS="--prerelease"
    log_info "Creating as PRE-RELEASE (beta)"
fi

gh release create "$TAG_NAME" \
    --title "${PROJECT_NAME} ${NEW_VERSION}" \
    --generate-notes \
    $RELEASE_FLAGS \
    $RELEASE_FILES

log_info "=========================================="
log_info "Release complete!"
log_info "=========================================="
log_info "Version: ${NEW_VERSION}"
log_info "Tag: ${TAG_NAME}"
log_info "URL: https://github.com/${GITHUB_REPO}/releases/tag/${TAG_NAME}"
