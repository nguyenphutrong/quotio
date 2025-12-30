#!/bin/bash
set -e

# =============================================================================
# Build CKota for Release
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

log_info "Building ${PROJECT_NAME}..."

# Clean previous build
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
mkdir -p "${RELEASE_DIR}"

# Build archive
log_step "Creating archive..."
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
    2>&1 | tee "${BUILD_DIR}/build.log"

if [ ! -d "${ARCHIVE_PATH}" ]; then
    log_error "Archive creation failed. Check ${BUILD_DIR}/build.log"
    exit 1
fi

# Extract app from archive (skip export which requires signing)
log_step "Extracting app from archive..."
cp -R "${ARCHIVE_PATH}/Products/Applications/${PROJECT_NAME}.app" "${APP_PATH}"

if [ ! -d "${APP_PATH}" ]; then
    log_error "Failed to extract app from archive"
    exit 1
fi

# Ad-hoc sign for local use
log_step "Ad-hoc signing app..."
codesign --force --deep --sign - "${APP_PATH}" 2>/dev/null || true

log_info "Build complete: ${APP_PATH}"
log_info "Version: $(get_version) (build $(get_build_number))"
