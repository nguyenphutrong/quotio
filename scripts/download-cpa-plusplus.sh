#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MANIFEST_PATH="${CPA_PLUSPLUS_BUNDLE_MANIFEST:-"$ROOT_DIR/Config/CPAPlusPlusBundle.json"}"
RESOURCE_DIR="${TARGET_BUILD_DIR:?TARGET_BUILD_DIR is required}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?UNLOCALIZED_RESOURCES_FOLDER_PATH is required}"
OUTPUT_PATH="$RESOURCE_DIR/cpa-plusplus"
OUTPUT_MANIFEST_PATH="$RESOURCE_DIR/CPAPlusPlusBundle.json"

mkdir -p "$RESOURCE_DIR"

copy_executable() {
  local source_path="$1"
  if [[ ! -f "$source_path" ]]; then
    echo "error: cpa-plusplus binary not found at $source_path" >&2
    exit 1
  fi
  cp "$source_path" "$OUTPUT_PATH"
  chmod 755 "$OUTPUT_PATH"
  if [[ -f "$MANIFEST_PATH" ]]; then
    cp "$MANIFEST_PATH" "$OUTPUT_MANIFEST_PATH"
  fi
  echo "Bundled cpa-plusplus from $source_path"
}

if [[ -n "${CPA_PLUSPLUS_BINARY_PATH:-}" ]]; then
  copy_executable "$CPA_PLUSPLUS_BINARY_PATH"
  exit 0
fi

if [[ ! -f "$MANIFEST_PATH" ]]; then
  echo "error: Missing cpa-plusplus bundle manifest: $MANIFEST_PATH" >&2
  exit 1
fi

ARCH_VALUE="${CURRENT_ARCH:-${NATIVE_ARCH_ACTUAL:-}}"
if [[ -z "$ARCH_VALUE" || "$ARCH_VALUE" == "undefined_arch" ]]; then
  ARCH_VALUE="$(uname -m)"
fi

case "$ARCH_VALUE" in
  arm64|aarch64)
    TARGET_KEY="darwin_aarch64"
    ;;
  x86_64|amd64)
    TARGET_KEY="darwin_amd64"
    ;;
  *)
    echo "error: Unsupported cpa-plusplus build architecture: $ARCH_VALUE" >&2
    exit 1
    ;;
esac

read_manifest_field() {
  local expression="$1"
  /usr/bin/python3 - "$MANIFEST_PATH" "$expression" <<'PY'
import json
import sys

path, expression = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as handle:
    value = json.load(handle)

for part in expression.split("."):
    value = value[part]

print(value)
PY
}

SOURCE_REPO="$(read_manifest_field "sourceRepo")"
TAG="$(read_manifest_field "tag")"
ASSET_NAME="$(read_manifest_field "assets.$TARGET_KEY.name")"
EXPECTED_SHA="$(read_manifest_field "assets.$TARGET_KEY.sha256")"

if [[ -z "$EXPECTED_SHA" ]]; then
  echo "error: Missing SHA256 for $TARGET_KEY in $MANIFEST_PATH" >&2
  echo "Set CPA_PLUSPLUS_BINARY_PATH for local development, or pin a released asset checksum." >&2
  exit 1
fi

CACHE_ROOT="${CPA_PLUSPLUS_BUILD_CACHE_DIR:-"$HOME/Library/Caches/QuotioBuild/cpa-plusplus"}"
CACHE_DIR="$CACHE_ROOT/$TAG/$TARGET_KEY"
CACHED_ASSET="$CACHE_DIR/$ASSET_NAME"
CACHED_BINARY="$CACHE_DIR/cpa-plusplus"
DOWNLOAD_URL="https://github.com/$SOURCE_REPO/releases/download/$TAG/$ASSET_NAME"

mkdir -p "$CACHE_DIR"

if [[ ! -f "$CACHED_ASSET" ]]; then
  echo "Downloading $DOWNLOAD_URL"
  /usr/bin/curl -fL --retry 3 --retry-delay 2 -o "$CACHED_ASSET" "$DOWNLOAD_URL"
fi

ACTUAL_SHA="$(/usr/bin/shasum -a 256 "$CACHED_ASSET" | awk '{print $1}')"
if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
  rm -f "$CACHED_ASSET"
  echo "error: SHA256 mismatch for $ASSET_NAME" >&2
  echo "expected: $EXPECTED_SHA" >&2
  echo "actual:   $ACTUAL_SHA" >&2
  exit 1
fi

rm -rf "$CACHE_DIR/extract"
mkdir -p "$CACHE_DIR/extract"

case "$ASSET_NAME" in
  *.zip)
    /usr/bin/ditto -x -k "$CACHED_ASSET" "$CACHE_DIR/extract"
    ;;
  *.tar.gz|*.tgz)
    /usr/bin/tar -xzf "$CACHED_ASSET" -C "$CACHE_DIR/extract"
    ;;
  *)
    cp "$CACHED_ASSET" "$CACHED_BINARY"
    ;;
esac

if [[ ! -f "$CACHED_BINARY" ]]; then
  FOUND_BINARY="$(/usr/bin/find "$CACHE_DIR/extract" -type f -name cpa-plusplus -perm -111 -print -quit)"
  if [[ -z "$FOUND_BINARY" ]]; then
    FOUND_BINARY="$(/usr/bin/find "$CACHE_DIR/extract" -type f -name cpa-plusplus -print -quit)"
  fi
  if [[ -z "$FOUND_BINARY" ]]; then
    echo "error: Release asset did not contain an executable named cpa-plusplus" >&2
    exit 1
  fi
  cp "$FOUND_BINARY" "$CACHED_BINARY"
fi

copy_executable "$CACHED_BINARY"
