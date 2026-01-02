#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

VERSION_ARG="${1:-}"
BETA_FLAG="${2:-}"

IS_BETA=false
if [[ "$VERSION_ARG" == *"-beta-"* ]] || [[ "$BETA_FLAG" == "--beta" ]]; then
    IS_BETA=true
fi

check_command xcodebuild
check_command xcrun
check_command gh

if ! gh auth status &>/dev/null; then
    log_error "GitHub CLI not authenticated"
    log_item "Run: gh auth login"
    exit 1
fi

if [ -n "$VERSION_ARG" ]; then
    NEW_VERSION=$("${SCRIPT_DIR}/bump-version.sh" "$VERSION_ARG")
else
    NEW_VERSION=$(get_version)
fi

TOTAL_STEPS=5
RELEASE_TYPE="Release"
[[ "$IS_BETA" == true ]] && RELEASE_TYPE="Beta Release"

print_header "${PROJECT_NAME} ${RELEASE_TYPE}" 55

print_summary "Release Configuration" \
    "Version" "v${NEW_VERSION}" \
    "Type" "${RELEASE_TYPE}" \
    "Repository" "${GITHUB_REPO}"

print_step 1 $TOTAL_STEPS "Building Application"
start_step_timer "build"

"${SCRIPT_DIR}/build.sh" 2>&1 | while read -r line; do
    if [[ "$line" == *"${SYM_CHECK}"* ]] || [[ "$line" == *"${SYM_CROSS}"* ]]; then
        echo "  $line"
    fi
done

log_success "Build completed ($(get_step_duration "build"))"

print_step 2 $TOTAL_STEPS "Notarizing"
start_step_timer "notarize"

if "${SCRIPT_DIR}/notarize.sh" 2>&1 | grep -qE "(complete|success|Skipping)"; then
    log_success "Notarization completed ($(get_step_duration "notarize"))"
else
    log_warn "Notarization skipped ($(get_step_duration "notarize"))"
fi

print_step 3 $TOTAL_STEPS "Packaging"
start_step_timer "package"

"${SCRIPT_DIR}/package.sh" >/dev/null 2>&1

log_success "Packaging completed ($(get_step_duration "package"))"

print_step 4 $TOTAL_STEPS "Generating Appcast"
start_step_timer "appcast"

"${SCRIPT_DIR}/generate-appcast.sh" >/dev/null 2>&1

log_success "Appcast generated ($(get_step_duration "appcast"))"

print_step 5 $TOTAL_STEPS "Creating GitHub Release"
start_step_timer "github"

TAG_NAME="v${NEW_VERSION}"
DMG_FILE="${RELEASE_DIR}/${PROJECT_NAME}-${NEW_VERSION}.dmg"
ZIP_FILE="${RELEASE_DIR}/${PROJECT_NAME}-${NEW_VERSION}.zip"

if [ ! -f "$DMG_FILE" ] && [ ! -f "$ZIP_FILE" ]; then
    log_failure "No release files found"
    log_item "Expected: ${DMG_FILE}"
    log_item "Expected: ${ZIP_FILE}"
    exit 1
fi

if ! git tag -l | grep -q "^${TAG_NAME}$"; then
    log_item "Creating git tag: ${TAG_NAME}"
    git tag -a "$TAG_NAME" -m "Release ${NEW_VERSION}"
    git push origin "$TAG_NAME"
else
    log_item "Tag ${TAG_NAME} already exists"
fi

RELEASE_FILES=""
[ -f "$DMG_FILE" ] && RELEASE_FILES="$RELEASE_FILES $DMG_FILE"
[ -f "$ZIP_FILE" ] && RELEASE_FILES="$RELEASE_FILES $ZIP_FILE"
[ -f "$APPCAST_PATH" ] && RELEASE_FILES="$RELEASE_FILES $APPCAST_PATH"

RELEASE_FLAGS=""
[[ "$IS_BETA" == true ]] && RELEASE_FLAGS="--prerelease"

gh release create "$TAG_NAME" \
    --title "${PROJECT_NAME} ${NEW_VERSION}" \
    --generate-notes \
    $RELEASE_FLAGS \
    $RELEASE_FILES >/dev/null 2>&1

log_success "GitHub release created ($(get_step_duration "github"))"

DMG_SIZE="N/A"
ZIP_SIZE="N/A"
[ -f "$DMG_FILE" ] && DMG_SIZE=$(get_file_size "$DMG_FILE")
[ -f "$ZIP_FILE" ] && ZIP_SIZE=$(get_file_size "$ZIP_FILE")

echo ""
print_divider "═" 55
echo ""

print_header "Release Complete ${SYM_ROCKET}" 55

print_summary "Artifacts" \
    "DMG" "${DMG_SIZE}" \
    "ZIP" "${ZIP_SIZE}"

print_summary "Release Details" \
    "Version" "v${NEW_VERSION}" \
    "Tag" "${TAG_NAME}" \
    "Duration" "$(get_total_duration)"

RELEASE_URL="https://github.com/${GITHUB_REPO}/releases/tag/${TAG_NAME}"
echo -e "  ${CYAN}${SYM_ARROW}${NC} ${RELEASE_URL}"
echo ""
