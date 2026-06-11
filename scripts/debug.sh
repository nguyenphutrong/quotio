#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODE="${1:-bundled}"

case "${MODE}" in
    dev|bundled)
        ;;
    *)
        echo "Usage: $0 [dev|bundled]" >&2
        exit 64
        ;;
esac

exec "${SCRIPT_DIR}/run-macos-shared-ui.sh" "${MODE}"
