#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

APP_TO_NOTARIZE="${1:-$APP_PATH}"

print_header "Notarization" 45

if [ ! -d "$APP_TO_NOTARIZE" ]; then
    log_failure "App not found: $APP_TO_NOTARIZE"
    log_item "Run ./scripts/build.sh first"
    exit 1
fi

if ! xcrun notarytool history --keychain-profile "$NOTARIZATION_KEYCHAIN_PROFILE" &>/dev/null; then
    log_warn "Notarization profile '${NOTARIZATION_KEYCHAIN_PROFILE}' not found"
    log_item "Setup: xcrun notarytool store-credentials \"$NOTARIZATION_KEYCHAIN_PROFILE\""
    log_item "Skipping notarization..."
    exit 0
fi

print_step 1 4 "Creating ZIP"
start_step_timer "zip"

ZIP_PATH="${BUILD_DIR}/${PROJECT_NAME}-notarize.zip"
ditto -c -k --keepParent "$APP_TO_NOTARIZE" "$ZIP_PATH"

ZIP_SIZE=$(get_file_size "$ZIP_PATH")
log_success "ZIP created: ${ZIP_SIZE} ($(get_step_duration "zip"))"

print_step 2 4 "Submitting to Apple"
start_step_timer "submit"

start_spinner "Submitting for notarization..."
xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$NOTARIZATION_KEYCHAIN_PROFILE" \
    --wait \
    > "${BUILD_DIR}/notarize.log" 2>&1
stop_spinner

log_success "Notarization submitted ($(get_step_duration "submit"))"

print_step 3 4 "Stapling Ticket"
start_step_timer "staple"

xcrun stapler staple "$APP_TO_NOTARIZE" >> "${BUILD_DIR}/notarize.log" 2>&1

log_success "Ticket stapled ($(get_step_duration "staple"))"

print_step 4 4 "Verifying"
start_step_timer "verify"

xcrun stapler validate "$APP_TO_NOTARIZE" >> "${BUILD_DIR}/notarize.log" 2>&1
spctl --assess --verbose=4 --type execute "$APP_TO_NOTARIZE" >> "${BUILD_DIR}/notarize.log" 2>&1

log_success "Verification passed ($(get_step_duration "verify"))"

rm -f "$ZIP_PATH"

echo ""
print_summary "Notarization Complete ${SYM_CHECK}" \
    "App" "$(basename "$APP_TO_NOTARIZE")" \
    "Status" "Signed & Notarized" \
    "Duration" "$(get_total_duration)"
