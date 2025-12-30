#!/bin/bash
set -e

# =============================================================================
# Package CKota as DMG
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

APP_TO_PACKAGE="${1:-$APP_PATH}"

if [ ! -d "$APP_TO_PACKAGE" ]; then
    log_error "App not found: $APP_TO_PACKAGE"
    log_info "Run ./scripts/build.sh first"
    exit 1
fi

VERSION=$(get_version)
DMG_NAME="${PROJECT_NAME}-${VERSION}.dmg"
FINAL_DMG="${RELEASE_DIR}/${DMG_NAME}"
ZIP_NAME="${PROJECT_NAME}-${VERSION}.zip"
FINAL_ZIP="${RELEASE_DIR}/${ZIP_NAME}"

log_info "Creating packages for version ${VERSION}..."

mkdir -p "${RELEASE_DIR}"

# Create ZIP for Sparkle updates
log_step "Creating ZIP for Sparkle..."
ditto -c -k --keepParent "$APP_TO_PACKAGE" "$FINAL_ZIP"
log_info "ZIP created: ${FINAL_ZIP}"

# Create DMG
log_step "Creating DMG..."

# Check if create-dmg is available
if command -v create-dmg &> /dev/null; then
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
        2>&1 || true  # create-dmg sometimes returns non-zero even on success
else
    log_warn "create-dmg not found. Creating simple DMG..."
    # Fallback to hdiutil
    TEMP_DMG="${BUILD_DIR}/temp.dmg"
    hdiutil create -volname "${PROJECT_NAME}" -srcfolder "${APP_TO_PACKAGE}" -ov -format UDRW "${TEMP_DMG}"
    hdiutil convert "${TEMP_DMG}" -format UDZO -o "${FINAL_DMG}"
    rm -f "${TEMP_DMG}"
fi

if [ -f "$FINAL_DMG" ]; then
    log_info "DMG created: ${FINAL_DMG}"
else
    log_warn "DMG creation may have failed. Check ${FINAL_DMG}"
fi

log_info "Packaging complete!"
log_info "  DMG: ${FINAL_DMG}"
log_info "  ZIP: ${FINAL_ZIP}"
