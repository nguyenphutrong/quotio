#!/bin/bash
set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

print_header "${PROJECT_NAME} Build" 50

VERSION=$(get_version)
BUILD_NUM=$(get_build_number)

print_summary "Build Configuration" \
    "Version" "${VERSION}" \
    "Build" "${BUILD_NUM}" \
    "Scheme" "${SCHEME}" \
    "Output" "${BUILD_DIR}"

if ! security find-identity -v -p codesigning | grep -Fq "${DEVELOPER_ID_APPLICATION}"; then
    log_failure "Developer ID Application certificate not available"
    log_item "Expected: ${DEVELOPER_ID_APPLICATION}"
    exit 1
fi

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
mkdir -p "${RELEASE_DIR}"

POSTHOG_BUILD_SETTINGS=()
if [ -n "${POSTHOG_PROJECT_TOKEN:-}" ]; then
    POSTHOG_BUILD_SETTINGS+=("POSTHOG_PROJECT_TOKEN=${POSTHOG_PROJECT_TOKEN}")
fi
if [ -n "${POSTHOG_HOST:-}" ]; then
    POSTHOG_BUILD_SETTINGS+=("POSTHOG_HOST=${POSTHOG_HOST}")
fi

print_step 1 4 "Creating Archive"
start_step_timer "archive"

xcodebuild archive \
    -project "${PROJECT_FILE}" \
    -scheme "${SCHEME}" \
    -configuration Release \
    -archivePath "${ARCHIVE_PATH}" \
    -derivedDataPath "${RELEASE_DERIVED_DATA}" \
    -destination "generic/platform=macOS" \
    SKIP_INSTALL=NO \
    BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="${DEVELOPER_ID_APPLICATION}" \
    DEVELOPMENT_TEAM="${DEVELOPER_TEAM_ID}" \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGNING_ALLOWED=YES \
    ENABLE_HARDENED_RUNTIME=YES \
    "${POSTHOG_BUILD_SETTINGS[@]}" \
    2>&1 | tee "${BUILD_DIR}/build.log" | while read -r line; do
        if [[ "$line" == *"error:"* ]]; then
            echo -e "  ${RED}${SYM_CROSS} ${line}${NC}"
        elif [[ "$line" == *"warning:"* ]]; then
            echo -e "  ${YELLOW}${SYM_WARN} ${line}${NC}"
        elif [[ "$line" == "** ARCHIVE SUCCEEDED **" ]]; then
            echo -e "  ${GREEN}${SYM_CHECK} Archive succeeded${NC}"
        elif [[ "$line" == "** ARCHIVE FAILED **" ]]; then
            echo -e "  ${RED}${SYM_CROSS} Archive failed${NC}"
        elif [[ "$line" == *"Compiling"* ]] || [[ "$line" == *"Linking"* ]]; then
            :
        fi
    done

ARCHIVE_DURATION=$(get_step_duration "archive")

if [ ! -d "${ARCHIVE_PATH}" ]; then
    log_failure "Archive creation failed"
    log_item "Check ${BUILD_DIR}/build.log for details"
    exit 1
fi
log_success "Archive created (${ARCHIVE_DURATION})"

print_step 2 4 "Extracting App"
start_step_timer "extract"

cp -R "${ARCHIVE_PATH}/Products/Applications/${PROJECT_NAME}.app" "${APP_PATH}"

if [ ! -d "${APP_PATH}" ]; then
    log_failure "Failed to extract app from archive"
    exit 1
fi
log_success "App extracted ($(get_step_duration "extract"))"

print_step 3 4 "Verifying Bundled Proxy"
start_step_timer "verify-proxy"

bash "${SCRIPT_DIR}/verify-bundled-proxy.sh" "${APP_PATH}"
log_success "Bundled proxy verified ($(get_step_duration "verify-proxy"))"

print_step 4 4 "Developer ID Signing"
start_step_timer "sign"

PROXY_BINARY="${APP_PATH}/Contents/Resources/Proxy/cli-proxy-api-plus"
ENTITLEMENTS_PATH="${BUILD_DIR}/${PROJECT_NAME}.entitlements.plist"
codesign -d --entitlements :- "${APP_PATH}" 2>/dev/null > "${ENTITLEMENTS_PATH}"
if [ -f "${PROXY_BINARY}" ]; then
    codesign --force --options runtime --timestamp \
        --sign "${DEVELOPER_ID_APPLICATION}" "${PROXY_BINARY}"
fi
codesign --force --options runtime --timestamp \
    --entitlements "${ENTITLEMENTS_PATH}" \
    --sign "${DEVELOPER_ID_APPLICATION}" "${APP_PATH}"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
log_success "App Developer ID signed ($(get_step_duration "sign"))"

APP_SIZE=$(get_file_size "${APP_PATH}")

echo ""
print_divider "═" 50
echo ""

print_summary "Build Complete ${SYM_SPARKLE}" \
    "App" "${APP_PATH}" \
    "Size" "${APP_SIZE}" \
    "Version" "${VERSION} (build ${BUILD_NUM})" \
    "Duration" "$(get_total_duration)"
