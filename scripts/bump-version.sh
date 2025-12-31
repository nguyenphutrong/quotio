#!/bin/bash
set -e

# =============================================================================
# Bump Version
# Usage: ./bump-version.sh [major|minor|patch] or ./bump-version.sh 1.2.3
#        ./bump-version.sh 1.2.3-beta-1 (for beta versions)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

PBXPROJ="${PROJECT_DIR}/${PROJECT_NAME}.xcodeproj/project.pbxproj"

# Get current version
CURRENT_VERSION=$(get_version)
CURRENT_BUILD=$(get_build_number)

log_info "Current version: ${CURRENT_VERSION} (build ${CURRENT_BUILD})"

# Parse version
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"

# Determine new version
case "${1:-}" in
    major)
        MAJOR=$((MAJOR + 1))
        MINOR=0
        PATCH=0
        ;;
    minor)
        MINOR=$((MINOR + 1))
        PATCH=0
        ;;
    patch)
        PATCH=$((PATCH + 1))
        ;;
    "")
        # No argument - just bump build number
        NEW_BUILD=$((CURRENT_BUILD + 1))
        sed -i '' "s/CURRENT_PROJECT_VERSION = ${CURRENT_BUILD}/CURRENT_PROJECT_VERSION = ${NEW_BUILD}/g" "$PBXPROJ"
        log_info "Build number bumped: ${CURRENT_BUILD} -> ${NEW_BUILD}"
        echo "${CURRENT_VERSION}"
        exit 0
        ;;
    *)
        # Support both X.Y.Z and X.Y.Z-beta-N formats
        if [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-beta-[0-9]+)?$ ]]; then
            BASE_VERSION=$(echo "$1" | sed 's/-beta-.*//')
            IFS='.' read -r MAJOR MINOR PATCH <<< "$BASE_VERSION"
            if [[ "$1" == *"-beta-"* ]]; then
                NEW_VERSION="$1"
            fi
        else
            log_error "Invalid version: $1"
            log_info "Usage: $0 [major|minor|patch|X.Y.Z|X.Y.Z-beta-N]"
            exit 1
        fi
        ;;
esac

NEW_VERSION="${NEW_VERSION:-${MAJOR}.${MINOR}.${PATCH}}"
NEW_BUILD=$((CURRENT_BUILD + 1))

log_info "New version: ${NEW_VERSION} (build ${NEW_BUILD})"

# Update project.pbxproj
sed -i '' "s/MARKETING_VERSION = ${CURRENT_VERSION}/MARKETING_VERSION = ${NEW_VERSION}/g" "$PBXPROJ"
sed -i '' "s/CURRENT_PROJECT_VERSION = ${CURRENT_BUILD}/CURRENT_PROJECT_VERSION = ${NEW_BUILD}/g" "$PBXPROJ"

log_info "Version updated successfully!"
echo "$NEW_VERSION"
