#!/bin/bash
set -e

# =============================================================================
# Notarize CKota App
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

APP_TO_NOTARIZE="${1:-$APP_PATH}"

if [ ! -d "$APP_TO_NOTARIZE" ]; then
    log_error "App not found: $APP_TO_NOTARIZE"
    log_info "Run ./scripts/build.sh first"
    exit 1
fi

# Check if notarization profile exists
if ! xcrun notarytool history --keychain-profile "$NOTARIZATION_KEYCHAIN_PROFILE" &>/dev/null; then
    log_warn "Notarization profile '$NOTARIZATION_KEYCHAIN_PROFILE' not found."
    log_info "Set up with: xcrun notarytool store-credentials \"$NOTARIZATION_KEYCHAIN_PROFILE\" --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID"
    log_info "Skipping notarization..."
    exit 0
fi

log_info "Creating ZIP for notarization..."
ZIP_PATH="${BUILD_DIR}/${PROJECT_NAME}-notarize.zip"
ditto -c -k --keepParent "$APP_TO_NOTARIZE" "$ZIP_PATH"

log_step "Submitting for notarization..."
xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$NOTARIZATION_KEYCHAIN_PROFILE" \
    --wait \
    2>&1 | tee "${BUILD_DIR}/notarize.log"

log_step "Stapling notarization ticket..."
xcrun stapler staple "$APP_TO_NOTARIZE"

log_step "Verifying notarization..."
xcrun stapler validate "$APP_TO_NOTARIZE"
spctl --assess --verbose=4 --type execute "$APP_TO_NOTARIZE"

log_info "Notarization complete!"
rm -f "$ZIP_PATH"
