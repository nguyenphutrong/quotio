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

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
mkdir -p "${RELEASE_DIR}"

print_step 1 3 "Creating Archive"
start_step_timer "archive"

xcodebuild archive \
    -project "${PROJECT_DIR}/${PROJECT_NAME}.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration Release \
    -archivePath "${ARCHIVE_PATH}" \
    -destination "generic/platform=macOS" \
    SKIP_INSTALL=NO \
    BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
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

print_step 2 3 "Extracting App"
start_step_timer "extract"

cp -R "${ARCHIVE_PATH}/Products/Applications/${PROJECT_NAME}.app" "${APP_PATH}"

if [ ! -d "${APP_PATH}" ]; then
    log_failure "Failed to extract app from archive"
    exit 1
fi
log_success "App extracted ($(get_step_duration "extract"))"

print_step 3 3 "Ad-hoc Signing"
start_step_timer "sign"

codesign --force --deep --sign - "${APP_PATH}" 2>/dev/null || true
log_success "App signed ($(get_step_duration "sign"))"

APP_SIZE=$(get_file_size "${APP_PATH}")

echo ""
print_divider "═" 50
echo ""

print_summary "Build Complete ${SYM_SPARKLE}" \
    "App" "${APP_PATH}" \
    "Size" "${APP_SIZE}" \
    "Version" "${VERSION} (build ${BUILD_NUM})" \
    "Duration" "$(get_total_duration)"
