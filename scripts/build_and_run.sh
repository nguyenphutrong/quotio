#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_NAME="Quotio"
PROJECT_FILE="${PROJECT_DIR}/${PROJECT_NAME}.xcodeproj"
BUILD_DIR="${PROJECT_DIR}/build"
DERIVED_DATA="${BUILD_DIR}/DebugDerivedData"
CACHE_OWNER_FILE="${DERIVED_DATA}/.project-path"
APP_PATH="${DERIVED_DATA}/Build/Products/Debug/${PROJECT_NAME}.app"
APP_BINARY="${APP_PATH}/Contents/MacOS/${PROJECT_NAME}"
BUNDLE_ID="app.bytrong.quotio"
MODE="run"

usage() {
    echo "Usage: $0 [--debug|--logs|--telemetry|--verify]"
    echo ""
    echo "Build the Debug app, stop any running Quotio process, and launch the fresh build."
    echo "  --debug      launch the app binary under lldb"
    echo "  --logs       launch and stream logs for the app process"
    echo "  --telemetry  launch and stream logs for subsystem ${BUNDLE_ID}"
    echo "  --verify     launch and confirm the process is running"
}

case "${1:-}" in
    "") ;;
    --debug|debug) MODE="debug" ;;
    --logs|logs) MODE="logs" ;;
    --telemetry|telemetry) MODE="telemetry" ;;
    --verify|verify) MODE="verify" ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 1
        ;;
esac

mkdir -p "${BUILD_DIR}"

if [ -d "${DERIVED_DATA}" ] && {
    [ ! -f "${CACHE_OWNER_FILE}" ] || [ "$(cat "${CACHE_OWNER_FILE}")" != "${PROJECT_DIR}" ]
}; then
    echo "==> Resetting DerivedData from another checkout"
    rm -rf "${DERIVED_DATA}"
fi

mkdir -p "${DERIVED_DATA}"
printf '%s\n' "${PROJECT_DIR}" > "${CACHE_OWNER_FILE}"

echo "==> Building ${PROJECT_NAME} (Debug)"
xcodebuild \
    -project "${PROJECT_FILE}" \
    -scheme "${PROJECT_NAME}" \
    -configuration Debug \
    -destination "platform=macOS" \
    -derivedDataPath "${DERIVED_DATA}" \
    build \
    2>&1 | tee "${BUILD_DIR}/debug-build.log"

if [ ! -d "${APP_PATH}" ]; then
    echo "error: built app not found at ${APP_PATH}" >&2
    exit 1
fi

echo "==> Stopping any running ${PROJECT_NAME} process"
pkill -x "${PROJECT_NAME}" 2>/dev/null || true
sleep 0.5

case "${MODE}" in
    run)
        /usr/bin/open -n "${APP_PATH}"
        ;;
    debug)
        echo "==> Launching under lldb; type 'run' to start"
        exec lldb -- "${APP_BINARY}"
        ;;
    logs)
        /usr/bin/open -n "${APP_PATH}"
        echo "==> Streaming process logs; press Ctrl-C to stop"
        exec /usr/bin/log stream --style compact --predicate "process == \"${PROJECT_NAME}\""
        ;;
    telemetry)
        /usr/bin/open -n "${APP_PATH}"
        echo "==> Streaming ${BUNDLE_ID} logs; press Ctrl-C to stop"
        exec /usr/bin/log stream --style compact --predicate "subsystem == \"${BUNDLE_ID}\""
        ;;
    verify)
        /usr/bin/open -n "${APP_PATH}"
        sleep 1
        if ! pgrep -x "${PROJECT_NAME}" >/dev/null; then
            echo "error: ${PROJECT_NAME} did not start" >&2
            exit 1
        fi
        echo "==> ${PROJECT_NAME} is running"
        ;;
esac

echo "==> App: ${APP_PATH}"
echo "==> Build log: ${BUILD_DIR}/debug-build.log"
