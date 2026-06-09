#!/bin/bash
# =============================================================================
# Quotio Dev Check - Fast compile check (no launch, no archive)
# =============================================================================
# Compiles the Debug target and prints only errors/warnings.
# Use this for tight inner-loop iteration while writing Swift.
# =============================================================================

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

print_header "${PROJECT_NAME} Compile Check" 50

DERIVED_DATA="${BUILD_DIR}/DerivedData"
mkdir -p "${BUILD_DIR}"

start_step_timer "check"

set +e
xcodebuild \
    -project "${PROJECT_DIR}/${PROJECT_NAME}.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration Debug \
    -destination "platform=macOS" \
    -derivedDataPath "${DERIVED_DATA}" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    build > "${BUILD_DIR}/dev-check.log" 2>&1
STATUS=$?
set -e

grep -E "(error:|warning:|\*\* BUILD)" "${BUILD_DIR}/dev-check.log" || true

DURATION=$(get_step_duration "check")

if [ "$STATUS" -eq 0 ]; then
    log_success "Build OK (${DURATION})"
else
    log_failure "Build FAILED (${DURATION})"
    log_item "See ${BUILD_DIR}/dev-check.log"
    exit "$STATUS"
fi
