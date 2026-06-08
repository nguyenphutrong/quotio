#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/config.sh"

SOURCE_REPO="nguyenphutrong/cpa-plusplus"
MANIFEST_PATH="${PROJECT_DIR}/Config/CPAPlusPlusBundle.json"
DRY_RUN=false
TARGET_TAG=""

usage() {
    cat <<EOF
Usage: $0 [--tag vX.Y.Z-plus.N] [--dry-run]

Updates Config/CPAPlusPlusBundle.json to the latest stable cpa++ release.

Options:
  --tag TAG    Use an explicit cpa++ release tag instead of latest stable
  --dry-run    Print the manifest that would be written without changing files
  -h, --help   Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag)
            TARGET_TAG="${2:-}"
            if [[ -z "$TARGET_TAG" ]]; then
                log_error "--tag requires a value" >&2
                exit 1
            fi
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

command -v gh >/dev/null 2>&1 || {
    log_error "gh is required to query cpa++ releases" >&2
    exit 1
}

command -v python3 >/dev/null 2>&1 || {
    log_error "python3 is required to update ${MANIFEST_PATH}" >&2
    exit 1
}

if [[ ! -f "$MANIFEST_PATH" ]]; then
    log_error "Manifest not found: ${MANIFEST_PATH}" >&2
    exit 1
fi

if [[ -z "$TARGET_TAG" ]]; then
    TARGET_TAG="$(gh release list \
        --repo "$SOURCE_REPO" \
        --exclude-drafts \
        --exclude-pre-releases \
        --limit 1 \
        --json tagName \
        -q '.[0].tagName')"
fi

if [[ -z "$TARGET_TAG" ]]; then
    log_error "Could not resolve latest cpa++ release tag" >&2
    exit 1
fi

VERSION="${TARGET_TAG#v}"
AARCH64_ASSET="cpa-plusplus_${VERSION}_darwin_aarch64.tar.gz"
AMD64_ASSET="cpa-plusplus_${VERSION}_darwin_amd64.tar.gz"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/quotio-cpa-bump.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

log_step "Fetching ${TARGET_TAG} checksums"
gh release download "$TARGET_TAG" \
    --repo "$SOURCE_REPO" \
    --pattern checksums.txt \
    --dir "$TMP_DIR" \
    --clobber >/dev/null

CHECKSUMS_PATH="${TMP_DIR}/checksums.txt"

read_checksum() {
    local asset_name="$1"
    awk -v name="$asset_name" '$2 == name { print $1 }' "$CHECKSUMS_PATH"
}

AARCH64_SHA="$(read_checksum "$AARCH64_ASSET")"
AMD64_SHA="$(read_checksum "$AMD64_ASSET")"

if [[ -z "$AARCH64_SHA" || -z "$AMD64_SHA" ]]; then
    log_error "Release ${TARGET_TAG} is missing expected macOS assets" >&2
    log_item "$AARCH64_ASSET: ${AARCH64_SHA:-missing}" >&2
    log_item "$AMD64_ASSET: ${AMD64_SHA:-missing}" >&2
    exit 1
fi

if [[ "$DRY_RUN" == true ]]; then
    OUTPUT_PATH="-"
else
    OUTPUT_PATH="$MANIFEST_PATH"
fi

python3 - "$MANIFEST_PATH" "$OUTPUT_PATH" "$SOURCE_REPO" "$TARGET_TAG" "$AARCH64_ASSET" "$AARCH64_SHA" "$AMD64_ASSET" "$AMD64_SHA" <<'PY'
import json
import sys

manifest_path, output_path, source_repo, tag, arm_asset, arm_sha, amd_asset, amd_sha = sys.argv[1:]

with open(manifest_path, "r", encoding="utf-8") as handle:
    manifest = json.load(handle)

manifest["sourceRepo"] = source_repo
manifest["tag"] = tag
manifest["assets"] = {
    "darwin_aarch64": {
        "name": arm_asset,
        "sha256": arm_sha,
    },
    "darwin_amd64": {
        "name": amd_asset,
        "sha256": amd_sha,
    },
}

content = json.dumps(manifest, indent=2) + "\n"

if output_path == "-":
    print(content, end="")
else:
    with open(output_path, "w", encoding="utf-8") as handle:
        handle.write(content)
PY

if [[ "$DRY_RUN" == true ]]; then
    log_info "Dry run only; ${MANIFEST_PATH} was not changed" >&2
else
    log_success "Updated cpa++ manifest to ${TARGET_TAG}" >&2
    log_item "$AARCH64_ASSET" >&2
    log_item "$AMD64_ASSET" >&2
fi
