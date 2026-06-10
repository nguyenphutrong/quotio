#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
PROJECT_NAME="Quotio"
SCHEME="${QUOTIO_MACOS_SCHEME:-Quotio}"
CONFIGURATION="${QUOTIO_MACOS_CONFIGURATION:-Debug}"
MODE="${1:-dev}"
DEV_SERVER="${QUOTIO_DESKTOP_UI_DEV_SERVER:-http://localhost:5173}"
DERIVED_DATA_PATH="${QUOTIO_MACOS_SHARED_UI_DERIVED_DATA:-${PROJECT_DIR}/build/DerivedDataSharedUI}"
APP_PATH="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}/${PROJECT_NAME}.app"
EXECUTABLE_PATH="${APP_PATH}/Contents/MacOS/${PROJECT_NAME}"
LOG_PATH="${PROJECT_DIR}/build/quotio-shared-ui.log"

case "${MODE}" in
    dev)
        if ! curl -fsS --max-time 2 "${DEV_SERVER}" >/dev/null; then
            echo "Desktop UI dev server is not reachable: ${DEV_SERVER}" >&2
            echo "Start it first with: bun --cwd apps/desktop-ui dev" >&2
            exit 1
        fi
        ;;
    bundled)
        bun --cwd "${PROJECT_DIR}/apps/desktop-ui" build
        ;;
    *)
        echo "Usage: $0 [dev|bundled]" >&2
        exit 64
        ;;
esac

xcodebuild \
    -project "${PROJECT_DIR}/${PROJECT_NAME}.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -derivedDataPath "${DERIVED_DATA_PATH}" \
    build

if [ ! -x "${EXECUTABLE_PATH}" ]; then
    echo "Built app executable was not found: ${EXECUTABLE_PATH}" >&2
    exit 1
fi

mkdir -p "$(dirname "${LOG_PATH}")"

osascript -e 'quit app id "dev.quotio.desktop"' >/dev/null 2>&1 || true
osascript -e 'quit app id "dev.quotio.desktop.beta"' >/dev/null 2>&1 || true

if [ "${MODE}" = "dev" ]; then
    QUOTIO_DESKTOP_UI_DEV_SERVER="${DEV_SERVER}" \
    QUOTIO_ENABLE_SHARED_UI=1 \
    "${EXECUTABLE_PATH}" >"${LOG_PATH}" 2>&1 &
else
    QUOTIO_ENABLE_SHARED_UI=1 \
    "${EXECUTABLE_PATH}" >"${LOG_PATH}" 2>&1 &
fi

echo "Launched ${APP_PATH}"
if [ "${MODE}" = "dev" ]; then
    echo "Desktop UI: ${DEV_SERVER}"
else
    echo "Desktop UI: bundled assets"
fi
echo "Log: ${LOG_PATH}"
