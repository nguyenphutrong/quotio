#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/config.sh"

print_header "${PROJECT_NAME} Local Deployment" 55

VERSION=$(get_version)

print_summary "Deployment Configuration" \
    "Version" "${VERSION}" \
    "Output" "${RELEASE_DIR}" \
    "Release Upload" "No"

print_step 1 3 "Building Application"
start_step_timer "build"
"${SCRIPT_DIR}/build.sh"
log_success "Build completed ($(get_step_duration "build"))"

print_step 2 3 "Notarizing If Configured"
start_step_timer "notarize"
"${SCRIPT_DIR}/notarize.sh"
log_success "Notarization step completed ($(get_step_duration "notarize"))"

print_step 3 3 "Packaging Local Artifacts"
start_step_timer "package"
"${SCRIPT_DIR}/package.sh"
log_success "Packaging completed ($(get_step_duration "package"))"

DMG_FILE="${RELEASE_DIR}/${PROJECT_NAME}-${VERSION}.dmg"
ZIP_FILE="${RELEASE_DIR}/${PROJECT_NAME}-${VERSION}.zip"

DMG_SIZE="N/A"
ZIP_SIZE="N/A"
[ -f "$DMG_FILE" ] && DMG_SIZE=$(get_file_size "$DMG_FILE")
[ -f "$ZIP_FILE" ] && ZIP_SIZE=$(get_file_size "$ZIP_FILE")

echo ""
print_divider "═" 55
echo ""

print_summary "Local Deployment Complete" \
    "DMG" "${DMG_FILE} (${DMG_SIZE})" \
    "ZIP" "${ZIP_FILE} (${ZIP_SIZE})" \
    "Duration" "$(get_total_duration)"
