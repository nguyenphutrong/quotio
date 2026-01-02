#!/bin/bash
set -e

# =============================================================================
# Quick Release Helper
# Usage: ./quick-release.sh VERSION [--beta]
# Example: ./quick-release.sh 0.5.0
#          ./quick-release.sh 0.5.0-beta-1
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

VERSION="${1:-}"
BETA_FLAG="${2:-}"

if [ -z "$VERSION" ]; then
    log_error "Usage: $0 VERSION [--beta]"
    log_info "Examples:"
    log_info "  $0 0.5.0          # Release version 0.5.0"
    log_info "  $0 0.5.0-beta-1   # Release beta version"
    log_info "  $0 patch          # Bump patch version and release"
    log_info "  $0 minor          # Bump minor version and release"
    exit 1
fi

IS_BETA=false
if [[ "$VERSION" == *"-beta"* ]] || [[ "$BETA_FLAG" == "--beta" ]]; then
    IS_BETA=true
fi

log_info "==========================================="
log_info "Quick Release for ${PROJECT_NAME}"
log_info "==========================================="
log_info "Version: ${VERSION}"
log_info "Beta: ${IS_BETA}"

read -p "Continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_warn "Aborted"
    exit 1
fi

cd "${PROJECT_DIR}"

if [ -n "$(git status --porcelain)" ]; then
    log_warn "Working directory has uncommitted changes"
    read -p "Commit all changes before release? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        git add -A
        git commit -m "chore: prepare release ${VERSION}"
    else
        log_error "Please commit or stash changes first"
        exit 1
    fi
fi

log_step "Step 1/3: Updating CHANGELOG..."
"${SCRIPT_DIR}/update-changelog.sh" "$VERSION" || true

if [ -n "$(git status --porcelain CHANGELOG.md)" ]; then
    git add CHANGELOG.md
    git commit -m "docs: update CHANGELOG for ${VERSION}"
fi

log_step "Step 2/3: Creating and pushing tag..."
TAG_NAME="v${VERSION}"

if git tag -l | grep -q "^${TAG_NAME}$"; then
    log_warn "Tag ${TAG_NAME} already exists"
    read -p "Delete and recreate? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        git tag -d "${TAG_NAME}"
        git push origin --delete "${TAG_NAME}" 2>/dev/null || true
    else
        log_error "Aborted"
        exit 1
    fi
fi

git tag -a "${TAG_NAME}" -m "Release ${VERSION}"
git push origin master
git push origin "${TAG_NAME}"

log_step "Step 3/3: Triggering GitHub Actions..."
log_info "==========================================="
log_info "Release initiated!"
log_info "==========================================="
log_info "Tag: ${TAG_NAME}"
log_info "GitHub Actions will now:"
log_info "  1. Build the app"
log_info "  2. Create DMG and ZIP"
log_info "  3. Generate signed appcast"
log_info "  4. Create GitHub Release"
log_info ""
log_info "Monitor progress at:"
log_info "  https://github.com/${GITHUB_REPO}/actions"
