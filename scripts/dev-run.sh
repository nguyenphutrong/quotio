#!/bin/bash
# =============================================================================
# Quotio Dev Run - Fast build & launch for development
# =============================================================================
# Builds the Debug configuration and launches the app.
# Usage:
#   ./scripts/dev-run.sh           # build + run
#   ./scripts/dev-run.sh --build   # build only
#   ./scripts/dev-run.sh --clean   # clean derived data then build + run
# =============================================================================

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

MODE="run"
CLEAN=false

for arg in "$@"; do
    case "$arg" in
        --build) MODE="build" ;;
        --clean) CLEAN=true ;;
        --run)   MODE="run" ;;
        -h|--help)
            echo "Usage: $0 [--build|--run] [--clean]"
            exit 0
            ;;
    esac
done

print_header "${PROJECT_NAME} Dev Run" 50

DERIVED_DATA="${BUILD_DIR}/DerivedData"
DEBUG_APP="${DERIVED_DATA}/Build/Products/Debug/${PROJECT_NAME}.app"

if [[ "$CLEAN" == true ]]; then
    print_step 1 3 "Cleaning derived data"
    start_step_timer "clean"
    rm -rf "${DERIVED_DATA}"
    log_success "Cleaned ($(get_step_duration "clean"))"
fi

print_step 2 3 "Building Debug"
start_step_timer "build"

xcodebuild \
    -project "${PROJECT_DIR}/${PROJECT_NAME}.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration Debug \
    -destination "platform=macOS" \
    -derivedDataPath "${DERIVED_DATA}" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    build 2>&1 | tee "${BUILD_DIR}/dev-build.log" | grep -E "^(error:|warning:|\*\* )" || true

if [ ! -d "${DEBUG_APP}" ]; then
    log_failure "Debug app not found at ${DEBUG_APP}"
    log_item "See ${BUILD_DIR}/dev-build.log for details"
    exit 1
fi
log_success "Build succeeded ($(get_step_duration "build"))"

if [[ "$MODE" == "build" ]]; then
    print_summary "Build Complete" \
        "App"     "${DEBUG_APP}" \
        "Log"     "${BUILD_DIR}/dev-build.log" \
        "Duration" "$(get_total_duration)"
    exit 0
fi

print_step 3 3 "Launching ${PROJECT_NAME}"
start_step_timer "launch"

# Kill any existing instance so we run the freshly built binary
pkill -x "${PROJECT_NAME}" 2>/dev/null || true
sleep 0.3

open "${DEBUG_APP}"
log_success "Launched ($(get_step_duration "launch"))"

print_summary "Dev Run Complete ${SYM_SPARKLE}" \
    "App"      "${DEBUG_APP}" \
    "Duration" "$(get_total_duration)"
