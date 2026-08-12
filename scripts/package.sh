#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

APP_TO_PACKAGE="${1:-$APP_PATH}"

print_header "Package Application" 45

if [ ! -d "$APP_TO_PACKAGE" ]; then
    log_failure "App not found: $APP_TO_PACKAGE"
    log_item "Run ./scripts/build.sh first"
    exit 1
fi

VERSION=$(get_version)
DMG_NAME="${PROJECT_NAME}-${VERSION}.dmg"
FINAL_DMG="${RELEASE_DIR}/${DMG_NAME}"
ZIP_NAME="${PROJECT_NAME}-${VERSION}.zip"
FINAL_ZIP="${RELEASE_DIR}/${ZIP_NAME}"
PKG_NAME="${PROJECT_NAME}-${VERSION}.pkg"
FINAL_PKG="${RELEASE_DIR}/${PKG_NAME}"

print_summary "Package Configuration" \
    "Version" "${VERSION}" \
    "App" "$(basename "$APP_TO_PACKAGE")" \
    "Output" "${RELEASE_DIR}"

mkdir -p "${RELEASE_DIR}"

if ! security find-identity -v -p basic | grep -Fq "${DEVELOPER_ID_INSTALLER}"; then
    log_failure "Developer ID Installer certificate not available"
    log_item "Expected: ${DEVELOPER_ID_INSTALLER}"
    exit 1
fi

print_step 1 3 "Creating ZIP"
start_step_timer "zip"

start_spinner "Creating Sparkle ZIP..."
ditto -c -k --keepParent "$APP_TO_PACKAGE" "$FINAL_ZIP"
stop_spinner

ZIP_SIZE=$(get_file_size "$FINAL_ZIP")
log_success "ZIP created: ${ZIP_SIZE} ($(get_step_duration "zip"))"

print_step 2 3 "Creating Signed Installer"
start_step_timer "pkg"

productbuild --component "${APP_TO_PACKAGE}" /Applications \
    --sign "${DEVELOPER_ID_INSTALLER}" "${FINAL_PKG}"
pkgutil --check-signature "${FINAL_PKG}" >/dev/null
PKG_SIZE=$(get_file_size "${FINAL_PKG}")
log_success "Signed installer created: ${PKG_SIZE} ($(get_step_duration "pkg"))"

print_step 3 3 "Creating DMG"
start_step_timer "dmg"

if command -v create-dmg &> /dev/null; then
    start_spinner "Creating DMG with custom layout..."
    create-dmg \
        --volname "${PROJECT_NAME}" \
        --window-pos 200 120 \
        --window-size 600 400 \
        --icon-size 100 \
        --icon "${PROJECT_NAME}.app" 150 190 \
        --hide-extension "${PROJECT_NAME}.app" \
        --app-drop-link 450 185 \
        --no-internet-enable \
        "${FINAL_DMG}" \
        "${APP_TO_PACKAGE}" \
        >/dev/null 2>&1 || true
    stop_spinner
else
    log_item "create-dmg not found, using hdiutil"
    start_spinner "Creating DMG..."
    TEMP_DMG="${BUILD_DIR}/temp.dmg"
    hdiutil create -volname "${PROJECT_NAME}" -srcfolder "${APP_TO_PACKAGE}" -ov -format UDRW "${TEMP_DMG}" >/dev/null 2>&1
    hdiutil convert "${TEMP_DMG}" -format UDZO -o "${FINAL_DMG}" >/dev/null 2>&1
    rm -f "${TEMP_DMG}"
    stop_spinner
fi

if [ -f "$FINAL_DMG" ]; then
    DMG_SIZE=$(get_file_size "$FINAL_DMG")
    log_success "DMG created: ${DMG_SIZE} ($(get_step_duration "dmg"))"
else
    log_warn "DMG creation may have failed"
fi

echo ""
print_divider "═" 45
echo ""

print_summary "Packages Created ${SYM_PACKAGE}" \
    "ZIP" "${ZIP_NAME} (${ZIP_SIZE})" \
    "Installer" "${PKG_NAME} (${PKG_SIZE})" \
    "DMG" "${DMG_NAME} (${DMG_SIZE:-N/A})" \
    "Duration" "$(get_total_duration)"
