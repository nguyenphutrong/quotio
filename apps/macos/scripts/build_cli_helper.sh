#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
MANIFEST="${REPOSITORY_ROOT}/apps/cli/Cargo.toml"
PROFILE="debug"
CARGO_ARGS=(build --manifest-path "${MANIFEST}" --locked)

if [ "${CONFIGURATION:-Debug}" = "Release" ]; then
    PROFILE="release"
    CARGO_ARGS+=(--release)
fi

if [ -n "${QUOTIO_CLI_BINARY:-}" ]; then
    [[ "${QUOTIO_CLI_BINARY}" = /* ]] || {
        echo "error: QUOTIO_CLI_BINARY must be an absolute path" >&2
        exit 1
    }
    CLI_BINARY="${QUOTIO_CLI_BINARY}"
else
    cargo "${CARGO_ARGS[@]}"
    CARGO_OUTPUT="$(cargo metadata --manifest-path "${MANIFEST}" --no-deps --format-version 1 \
        | sed -n 's/.*"target_directory":"\([^"]*\)".*/\1/p')"
    [ -n "${CARGO_OUTPUT}" ] || {
        echo "error: unable to resolve Cargo target directory" >&2
        exit 1
    }
    CLI_BINARY="${CARGO_OUTPUT}/${PROFILE}/quotio"
fi

[ -x "${CLI_BINARY}" ] || {
    echo "error: Quotio CLI helper is missing or not executable: ${CLI_BINARY}" >&2
    exit 1
}

DESTINATION="${TARGET_BUILD_DIR:?}/${CONTENTS_FOLDER_PATH:?}/Helpers/quotio-cli"
mkdir -p "$(dirname "${DESTINATION}")"
cp "${CLI_BINARY}" "${DESTINATION}"
chmod 755 "${DESTINATION}"
"${DESTINATION}" --version >/dev/null
