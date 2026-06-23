#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_FILE="${PROJECT_DIR}/Quotio.xcodeproj"
SCHEME="Quotio"
CONFIGURATION="Debug"
DERIVED_DATA_PATH="${PROJECT_DIR}/build/VerifyDerivedData"
DESTINATION="platform=macOS"

log() {
    echo "==> $1"
}

warn() {
    echo "warning: $1"
}

fail() {
    echo "error: $1" >&2
    exit 1
}

run_step() {
    local name="$1"
    shift

    log "${name}"
    if ! "$@"; then
        fail "${name} failed"
    fi
}

has_test_target() {
    xcodebuild -list -project "${PROJECT_FILE}" 2>/dev/null \
        | awk '
            $0 ~ /^[[:space:]]*Targets:/ { in_targets = 1; next }
            $0 ~ /^[[:space:]]*Build Configurations:/ { in_targets = 0 }
            in_targets && $0 ~ /Tests?[[:space:]]*$/ { found = 1 }
            END { exit(found ? 0 : 1) }
        '
}

cd "${PROJECT_DIR}"

if [ ! -d "${PROJECT_FILE}" ]; then
    fail "Expected Xcode project not found: ${PROJECT_FILE}"
fi

run_step "Build" \
    xcodebuild \
        -project "${PROJECT_FILE}" \
        -scheme "${SCHEME}" \
        -configuration "${CONFIGURATION}" \
        -destination "${DESTINATION}" \
        -derivedDataPath "${DERIVED_DATA_PATH}" \
        build \
        CODE_SIGN_IDENTITY="-" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO

if command -v swiftlint >/dev/null 2>&1; then
    run_step "SwiftLint" swiftlint lint
else
    warn "SwiftLint is not installed; skipping lint"
fi

if has_test_target; then
    run_step "Tests" \
        xcodebuild \
            -project "${PROJECT_FILE}" \
            -scheme "${SCHEME}" \
            -configuration "${CONFIGURATION}" \
            -destination "${DESTINATION}" \
            -derivedDataPath "${DERIVED_DATA_PATH}" \
            test \
            CODE_SIGN_IDENTITY="-" \
            CODE_SIGNING_REQUIRED=NO \
            CODE_SIGNING_ALLOWED=NO
else
    warn "No Xcode test targets found; skipping tests"
fi

log "All available checks passed"
