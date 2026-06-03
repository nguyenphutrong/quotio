#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/config.sh"
# This verifier does not start config.sh spinners; avoid clearing the caller's last output line.
trap - EXIT

APP_TO_VERIFY="${1:-${PROJECT_DIR}/build/Quotio.app}"
BINARY_NAME="cpa-plusplus"
RESOURCE_SUBDIRECTORY="Proxy"
MANIFEST_NAME="CPAPlusPlusBundle.json"
SOURCE_MANIFEST_PATH="${PROJECT_DIR}/Config/${MANIFEST_NAME}"

fail() {
    log_failure "Bundled proxy verification failed"
    log_item "$1"
    exit 1
}

[ -d "${APP_TO_VERIFY}" ] || fail "app not found: ${APP_TO_VERIFY}"
[ -f "${SOURCE_MANIFEST_PATH}" ] || fail "source manifest not found: ${SOURCE_MANIFEST_PATH}"

RESOURCES_DIR="${APP_TO_VERIFY}/Contents/Resources"
SUBDIR_BINARY="${RESOURCES_DIR}/${RESOURCE_SUBDIRECTORY}/${BINARY_NAME}"
ROOT_BINARY="${RESOURCES_DIR}/${BINARY_NAME}"
SUBDIR_MANIFEST="${RESOURCES_DIR}/${RESOURCE_SUBDIRECTORY}/${MANIFEST_NAME}"
ROOT_MANIFEST="${RESOURCES_DIR}/${MANIFEST_NAME}"

BINARY_PATH=""
if [ -f "${SUBDIR_BINARY}" ]; then
    BINARY_PATH="${SUBDIR_BINARY}"
elif [ -f "${ROOT_BINARY}" ]; then
    BINARY_PATH="${ROOT_BINARY}"
else
    fail "missing ${BINARY_NAME}; checked ${SUBDIR_BINARY} and ${ROOT_BINARY}"
fi

MANIFEST_PATH=""
if [ -f "${SUBDIR_MANIFEST}" ]; then
    MANIFEST_PATH="${SUBDIR_MANIFEST}"
elif [ -f "${ROOT_MANIFEST}" ]; then
    MANIFEST_PATH="${ROOT_MANIFEST}"
else
    fail "missing ${MANIFEST_NAME}; checked ${SUBDIR_MANIFEST} and ${ROOT_MANIFEST}"
fi

case "$(uname -m)" in
    arm64|aarch64) MANIFEST_ASSET_KEY="darwin_aarch64" ;;
    x86_64|amd64) MANIFEST_ASSET_KEY="darwin_amd64" ;;
    *) fail "unsupported build architecture: $(uname -m)" ;;
esac

EXPECTED_SHA256="$(python3 - "$MANIFEST_PATH" "$MANIFEST_ASSET_KEY" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    manifest = json.load(handle)

print(manifest.get("assets", {}).get(sys.argv[2], {}).get("sha256", ""))
PY
)"
[ -n "${EXPECTED_SHA256}" ] || fail "could not read ${MANIFEST_ASSET_KEY} sha256 from ${MANIFEST_PATH}"

cmp -s "${SOURCE_MANIFEST_PATH}" "${MANIFEST_PATH}" || fail "bundled manifest differs from ${SOURCE_MANIFEST_PATH}"
[ -x "${BINARY_PATH}" ] || fail "bundled binary is not executable: ${BINARY_PATH}"

log_success "Bundled proxy verified: ${BINARY_PATH} (${MANIFEST_ASSET_KEY})"
