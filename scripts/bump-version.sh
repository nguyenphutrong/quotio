#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

PBXPROJ="${PROJECT_DIR}/${PROJECT_NAME}.xcodeproj/project.pbxproj"

CURRENT_VERSION=$(get_version)
CURRENT_BUILD=$(get_build_number)

IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"

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
        NEW_BUILD=$((CURRENT_BUILD + 1))
        sed -i '' "s/CURRENT_PROJECT_VERSION = ${CURRENT_BUILD}/CURRENT_PROJECT_VERSION = ${NEW_BUILD}/g" "$PBXPROJ"
        log_info "Build: ${CURRENT_BUILD} ${SYM_ARROW} ${NEW_BUILD}" >&2
        echo "${CURRENT_VERSION}"
        exit 0
        ;;
    *)
        if [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-beta-[0-9]+)?$ ]]; then
            if [[ "$1" == "$CURRENT_VERSION" ]]; then
                log_info "Already at v$1" >&2
                echo "$CURRENT_VERSION"
                exit 0
            fi
            BASE_VERSION=$(echo "$1" | sed 's/-beta-.*//')
            IFS='.' read -r MAJOR MINOR PATCH <<< "$BASE_VERSION"
            if [[ "$1" == *"-beta-"* ]]; then
                NEW_VERSION="$1"
            fi
        else
            log_error "Invalid version: $1" >&2
            log_item "Usage: $0 [major|minor|patch|X.Y.Z|X.Y.Z-beta-N]" >&2
            exit 1
        fi
        ;;
esac

NEW_VERSION="${NEW_VERSION:-${MAJOR}.${MINOR}.${PATCH}}"
NEW_BUILD=$((CURRENT_BUILD + 1))

sed -i '' "s/MARKETING_VERSION = ${CURRENT_VERSION}/MARKETING_VERSION = ${NEW_VERSION}/g" "$PBXPROJ"
sed -i '' "s/CURRENT_PROJECT_VERSION = ${CURRENT_BUILD}/CURRENT_PROJECT_VERSION = ${NEW_BUILD}/g" "$PBXPROJ"

log_success "Version: ${CURRENT_VERSION} ${SYM_ARROW} ${NEW_VERSION}" >&2
log_item "Build: ${CURRENT_BUILD} ${SYM_ARROW} ${NEW_BUILD}" >&2

echo "$NEW_VERSION"
