#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

print_header "Generate Appcast" 45

SPARKLE_DIR="${PROJECT_DIR}/.sparkle"
SPARKLE_BIN="${SPARKLE_DIR}/bin"
GENERATE_APPCAST="${SPARKLE_BIN}/generate_appcast"

if [ ! -f "$GENERATE_APPCAST" ]; then
    print_step 1 2 "Downloading Sparkle Tools"
    start_step_timer "download"
    
    mkdir -p "${SPARKLE_DIR}"
    
    SPARKLE_VERSION="2.6.4"
    SPARKLE_URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
    
    start_spinner "Downloading Sparkle ${SPARKLE_VERSION}..."
    curl -sL "$SPARKLE_URL" | tar xJ -C "${SPARKLE_DIR}"
    stop_spinner
    
    if [ ! -f "$GENERATE_APPCAST" ]; then
        log_failure "Failed to download Sparkle tools"
        exit 1
    fi
    log_success "Sparkle tools installed ($(get_step_duration "download"))"
else
    log_item "Sparkle tools already installed"
fi

if [ ! -d "$RELEASE_DIR" ] || [ -z "$(ls -A "$RELEASE_DIR" 2>/dev/null)" ]; then
    log_failure "No release files found in ${RELEASE_DIR}"
    log_item "Run ./scripts/package.sh first"
    exit 1
fi

print_step 2 2 "Generating Appcast"
start_step_timer "generate"

DMG_FILES=$(find "$RELEASE_DIR" -name "*.dmg" -type f 2>/dev/null)
TEMP_DMG_DIR="${BUILD_DIR}/dmg_temp"
if [ -n "$DMG_FILES" ]; then
    mkdir -p "$TEMP_DMG_DIR"
    for dmg in $DMG_FILES; do
        mv "$dmg" "$TEMP_DMG_DIR/"
    done
    log_item "Temporarily moved DMG files"
fi

start_spinner "Generating appcast..."
"$GENERATE_APPCAST" "${RELEASE_DIR}" 2>/dev/null
stop_spinner

if [ -d "$TEMP_DMG_DIR" ] && [ -n "$(ls -A "$TEMP_DMG_DIR" 2>/dev/null)" ]; then
    mv "$TEMP_DMG_DIR"/*.dmg "$RELEASE_DIR/"
    rmdir "$TEMP_DMG_DIR"
    log_item "Restored DMG files"
fi

if [ -f "${APPCAST_PATH}" ]; then
    CURRENT_VERSION=$(get_version)
    
    sed -i '' "s|/releases/latest/download/|/releases/download/v${CURRENT_VERSION}/|g" "${APPCAST_PATH}"
    log_item "Fixed download URL to v${CURRENT_VERSION}"
    
    if [[ "$CURRENT_VERSION" == *"-beta"* ]] || [[ "$CURRENT_VERSION" == *"-alpha"* ]] || [[ "$CURRENT_VERSION" == *"-rc"* ]]; then
        sed -i '' 's|</sparkle:shortVersionString>|</sparkle:shortVersionString>\n            <sparkle:channel>beta</sparkle:channel>|g' "${APPCAST_PATH}"
        log_item "Added beta channel tag"
    fi
    
    log_success "Appcast generated ($(get_step_duration "generate"))"
    
    APPCAST_SIZE=$(get_file_size "${APPCAST_PATH}")
    
    echo ""
    print_summary "Appcast Details" \
        "File" "appcast.xml" \
        "Size" "${APPCAST_SIZE}" \
        "Version" "${CURRENT_VERSION}"
else
    log_failure "Appcast generation failed"
    exit 1
fi
