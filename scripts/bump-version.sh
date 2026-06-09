#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

PBXPROJ="${PROJECT_DIR}/${PROJECT_NAME}.xcodeproj/project.pbxproj"

CURRENT_VERSION=$(get_version)
CURRENT_BUILD=$(get_build_number)

get_latest_release_build_number() {
    local appcast_name="${APPCAST_FILENAME:-appcast.xml}"
    local appcast_url="https://github.com/${GITHUB_REPO}/releases/latest/download/${appcast_name}"
    local appcast

    if ! command -v curl >/dev/null 2>&1; then
        return 0
    fi

    appcast=$(curl -fsSL "$appcast_url" 2>/dev/null || true)
    if [ -z "$appcast" ]; then
        return 0
    fi

    echo "$appcast" \
        | sed -n 's/.*<sparkle:version>\([0-9][0-9]*\)<\/sparkle:version>.*/\1/p' \
        | sort -nr \
        | head -1
}

next_build_number() {
    local candidate=$((CURRENT_BUILD + 1))
    local latest_release_build

    latest_release_build=$(get_latest_release_build_number)
    if [[ "$latest_release_build" =~ ^[0-9]+$ ]] && [ "$candidate" -le "$latest_release_build" ]; then
        candidate=$((latest_release_build + 1))
    fi

    echo "$candidate"
}

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
        NEW_BUILD=$(next_build_number)
        sed -i '' "s/CURRENT_PROJECT_VERSION = ${CURRENT_BUILD}/CURRENT_PROJECT_VERSION = ${NEW_BUILD}/g" "$PBXPROJ"
        log_info "Build: ${CURRENT_BUILD} ${SYM_ARROW} ${NEW_BUILD}" >&2
        echo "${CURRENT_VERSION}"
        exit 0
        ;;
    *)
        if [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)-[0-9]+)?$ ]]; then
            if [[ "$1" == "$CURRENT_VERSION" ]]; then
                NEW_BUILD=$(next_build_number)
                sed -i '' "s/CURRENT_PROJECT_VERSION = ${CURRENT_BUILD}/CURRENT_PROJECT_VERSION = ${NEW_BUILD}/g" "$PBXPROJ"
                log_info "Already at v$1" >&2
                log_item "Build: ${CURRENT_BUILD} ${SYM_ARROW} ${NEW_BUILD}" >&2
                echo "$CURRENT_VERSION"
                exit 0
            fi
            BASE_VERSION=$(echo "$1" | sed -E 's/-(alpha|beta|rc)-.*//')
            IFS='.' read -r MAJOR MINOR PATCH <<< "$BASE_VERSION"
            if [[ "$1" =~ -(alpha|beta|rc)- ]]; then
                NEW_VERSION="$1"
            fi
        else
            log_error "Invalid version: $1" >&2
            log_item "Usage: $0 [major|minor|patch|X.Y.Z|X.Y.Z-alpha-N|X.Y.Z-beta-N|X.Y.Z-rc-N]" >&2
            exit 1
        fi
        ;;
esac

NEW_VERSION="${NEW_VERSION:-${MAJOR}.${MINOR}.${PATCH}}"
NEW_BUILD=$(next_build_number)

sed -i '' "s/MARKETING_VERSION = ${CURRENT_VERSION}/MARKETING_VERSION = ${NEW_VERSION}/g" "$PBXPROJ"
sed -i '' "s/CURRENT_PROJECT_VERSION = ${CURRENT_BUILD}/CURRENT_PROJECT_VERSION = ${NEW_BUILD}/g" "$PBXPROJ"

log_success "Version: ${CURRENT_VERSION} ${SYM_ARROW} ${NEW_VERSION}" >&2
log_item "Build: ${CURRENT_BUILD} ${SYM_ARROW} ${NEW_BUILD}" >&2

echo "$NEW_VERSION"
