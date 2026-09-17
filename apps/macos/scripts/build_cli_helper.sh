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
    CARGO_OUTPUT="$(cargo metadata --manifest-path "${MANIFEST}" --no-deps --format-version 1 \
        | sed -n 's/.*"target_directory":"\([^"]*\)".*/\1/p')"
    [ -n "${CARGO_OUTPUT}" ] || {
        echo "error: unable to resolve Cargo target directory" >&2
        exit 1
    }
    CLI_BINARIES=()
    for arch in ${ARCHS:-$(uname -m)}; do
        case "${arch}" in
            arm64) target="aarch64-apple-darwin" ;;
            x86_64) target="x86_64-apple-darwin" ;;
            *)
                echo "error: unsupported Quotio CLI architecture: ${arch}" >&2
                exit 1
                ;;
        esac
        cargo "${CARGO_ARGS[@]}" --target "${target}"
        CLI_BINARIES+=("${CARGO_OUTPUT}/${target}/${PROFILE}/quotio")
    done
fi

DESTINATION="${TARGET_BUILD_DIR:?}/${CONTENTS_FOLDER_PATH:?}/Helpers/quotio-cli"
mkdir -p "$(dirname "${DESTINATION}")"
if [ -n "${CLI_BINARY:-}" ]; then
    cp "${CLI_BINARY}" "${DESTINATION}"
elif [ "${#CLI_BINARIES[@]}" -eq 1 ]; then
    cp "${CLI_BINARIES[0]}" "${DESTINATION}"
else
    lipo -create "${CLI_BINARIES[@]}" -output "${DESTINATION}"
fi
chmod 755 "${DESTINATION}"
for arch in ${ARCHS:-$(uname -m)}; do
    lipo -verify_arch "${arch}" "${DESTINATION}"
done
"${DESTINATION}" --version >/dev/null
