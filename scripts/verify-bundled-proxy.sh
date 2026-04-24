#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_TO_VERIFY="${1:-${PROJECT_DIR}/build/Quotio.app}"
BINARY_NAME="cli-proxy-api-plus"
RESOURCE_SUBDIRECTORY="Proxy"
MODEL_SOURCE="${PROJECT_DIR}/Quotio/Models/ProxyVersionModels.swift"

fail() {
    echo "Bundled proxy verification failed: $1" >&2
    exit 1
}

[ -d "${APP_TO_VERIFY}" ] || fail "app not found: ${APP_TO_VERIFY}"
[ -f "${MODEL_SOURCE}" ] || fail "model source not found: ${MODEL_SOURCE}"

EXPECTED_SHA256="$(
    sed -n 's/.*static let plusLocalSHA256 = "\([0-9a-fA-F]\{64\}\)".*/\1/p' "${MODEL_SOURCE}" | head -n 1
)"
[ -n "${EXPECTED_SHA256}" ] || fail "could not read plusLocalSHA256 from ${MODEL_SOURCE}"

RESOURCES_DIR="${APP_TO_VERIFY}/Contents/Resources"
SUBDIR_BINARY="${RESOURCES_DIR}/${RESOURCE_SUBDIRECTORY}/${BINARY_NAME}"
ROOT_BINARY="${RESOURCES_DIR}/${BINARY_NAME}"

BINARY_PATH=""
if [ -f "${SUBDIR_BINARY}" ]; then
    BINARY_PATH="${SUBDIR_BINARY}"
elif [ -f "${ROOT_BINARY}" ]; then
    BINARY_PATH="${ROOT_BINARY}"
else
    fail "missing ${BINARY_NAME}; checked ${SUBDIR_BINARY} and ${ROOT_BINARY}"
fi

ACTUAL_SHA256="$(shasum -a 256 "${BINARY_PATH}" | awk '{print $1}')"
if [ "${ACTUAL_SHA256}" != "${EXPECTED_SHA256}" ]; then
    fail "checksum mismatch for ${BINARY_PATH}; expected ${EXPECTED_SHA256}, got ${ACTUAL_SHA256}"
fi

echo "Bundled proxy verified: ${BINARY_PATH}"
