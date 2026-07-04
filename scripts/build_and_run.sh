#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/config.sh"

MODE="run"

case "${1:-}" in
    "")
        ;;
    --debug|debug)
        MODE="debug"
        ;;
    --logs|logs)
        MODE="logs"
        ;;
    --telemetry|telemetry)
        MODE="telemetry"
        ;;
    --verify|verify)
        MODE="verify"
        ;;
    -h|--help)
        echo "Usage: $0 [--debug|--logs|--telemetry|--verify]"
        echo ""
        echo "Builds the Debug app, stops any running ${PROJECT_NAME} process, and launches the fresh app."
        echo "  --debug      launch the built app binary under lldb"
        echo "  --logs       launch and stream unified logs for the app process"
        echo "  --telemetry  launch and stream unified logs for subsystem ${BUNDLE_ID}"
        echo "  --verify     launch and confirm the process is running"
        exit 0
        ;;
    *)
        log_error "Unknown option: $1"
        log_item "Usage: $0 [--debug|--logs|--telemetry|--verify]"
        exit 1
        ;;
esac

print_header "${PROJECT_NAME} Build & Run" 55

print_step 1 3 "Building Debug App"
start_step_timer "debug-build"

mkdir -p "${BUILD_DIR}"

xcodebuild \
    -project "${PROJECT_FILE}" \
    -scheme "${SCHEME}" \
    -configuration Debug \
    -destination "${DESTINATION}" \
    -derivedDataPath "${DEBUG_DERIVED_DATA}" \
    build \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    2>&1 | tee "${BUILD_DIR}/debug-build.log" | while read -r line; do
        if [[ "$line" == *"error:"* ]]; then
            echo -e "  ${RED}${SYM_CROSS} ${line}${NC}"
        elif [[ "$line" == *"warning:"* ]]; then
            echo -e "  ${YELLOW}${SYM_WARN} ${line}${NC}"
        elif [[ "$line" == "** BUILD SUCCEEDED **" ]]; then
            echo -e "  ${GREEN}${SYM_CHECK} Build succeeded${NC}"
        elif [[ "$line" == "** BUILD FAILED **" ]]; then
            echo -e "  ${RED}${SYM_CROSS} Build failed${NC}"
        fi
    done

if [ ! -d "${DEBUG_APP_PATH}" ]; then
    log_failure "Failed to find built app"
    log_item "Expected: ${DEBUG_APP_PATH}"
    log_item "Check ${BUILD_DIR}/debug-build.log"
    exit 1
fi

log_success "Debug app built ($(get_step_duration "debug-build"))"

print_step 2 3 "Stopping Existing App"
start_step_timer "stop"

pkill -x "${PROJECT_NAME}" 2>/dev/null || true
sleep 0.5

log_success "Existing process stopped if present ($(get_step_duration "stop"))"

print_step 3 3 "Launching App"
start_step_timer "launch"

case "$MODE" in
    run)
        /usr/bin/open -n "${DEBUG_APP_PATH}"
        log_success "App launched ($(get_step_duration "launch"))"
        ;;
    debug)
        log_step "Launching under lldb. Type 'run' inside lldb to start."
        exec lldb -- "${DEBUG_APP_BINARY}"
        ;;
    logs)
        /usr/bin/open -n "${DEBUG_APP_PATH}"
        log_success "App launched ($(get_step_duration "launch"))"
        log_step "Streaming process logs. Press Ctrl-C to stop."
        exec /usr/bin/log stream --style compact --predicate "process == \"${PROJECT_NAME}\""
        ;;
    telemetry)
        /usr/bin/open -n "${DEBUG_APP_PATH}"
        log_success "App launched ($(get_step_duration "launch"))"
        log_step "Streaming subsystem logs for ${BUNDLE_ID}. Press Ctrl-C to stop."
        exec /usr/bin/log stream --style compact --predicate "subsystem == \"${BUNDLE_ID}\""
        ;;
    verify)
        /usr/bin/open -n "${DEBUG_APP_PATH}"
        sleep 1
        if pgrep -x "${PROJECT_NAME}" >/dev/null; then
            log_success "${PROJECT_NAME} process is running"
        else
            log_failure "${PROJECT_NAME} process was not found after launch"
            exit 1
        fi
        ;;
esac

print_summary "Debug Build Complete" \
    "App" "${DEBUG_APP_PATH}" \
    "Log" "${BUILD_DIR}/debug-build.log" \
    "Duration" "$(get_total_duration)"
