#!/bin/bash
set -e

# =============================================================================
# Generate Sparkle Appcast
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

log_info "Generating appcast..."

# Sparkle tools location
SPARKLE_DIR="${PROJECT_DIR}/.sparkle"
SPARKLE_BIN="${SPARKLE_DIR}/bin"
GENERATE_APPCAST="${SPARKLE_BIN}/generate_appcast"

# Download Sparkle tools if not present
if [ ! -f "$GENERATE_APPCAST" ]; then
    log_step "Downloading Sparkle tools..."
    mkdir -p "${SPARKLE_DIR}"
    
    SPARKLE_VERSION="2.6.4"
    SPARKLE_URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
    
    curl -L "$SPARKLE_URL" | tar xJ -C "${SPARKLE_DIR}"
    
    if [ ! -f "$GENERATE_APPCAST" ]; then
        log_error "Failed to download Sparkle tools"
        exit 1
    fi
    log_info "Sparkle tools downloaded to ${SPARKLE_DIR}"
fi

# Check if there are files to process
if [ ! -d "$RELEASE_DIR" ] || [ -z "$(ls -A "$RELEASE_DIR" 2>/dev/null)" ]; then
    log_error "No release files found in ${RELEASE_DIR}"
    log_info "Run ./scripts/package.sh first"
    exit 1
fi

# Temporarily move DMG files to avoid Sparkle duplicate version error
# Sparkle only supports one archive per version
DMG_FILES=$(find "$RELEASE_DIR" -name "*.dmg" -type f 2>/dev/null)
TEMP_DMG_DIR="${BUILD_DIR}/dmg_temp"
if [ -n "$DMG_FILES" ]; then
    mkdir -p "$TEMP_DMG_DIR"
    for dmg in $DMG_FILES; do
        mv "$dmg" "$TEMP_DMG_DIR/"
    done
    log_info "Temporarily moved DMG files for appcast generation"
fi

# Generate appcast (uses Keychain for signing)
log_step "Generating appcast from ${RELEASE_DIR}..."
"$GENERATE_APPCAST" "${RELEASE_DIR}"

# Restore DMG files
if [ -d "$TEMP_DMG_DIR" ] && [ -n "$(ls -A "$TEMP_DMG_DIR" 2>/dev/null)" ]; then
    mv "$TEMP_DMG_DIR"/*.dmg "$RELEASE_DIR/"
    rmdir "$TEMP_DMG_DIR"
    log_info "Restored DMG files"
fi

if [ -f "${APPCAST_PATH}" ]; then
    log_info "Appcast generated: ${APPCAST_PATH}"
    
    # Get current version to check if it's a beta
    CURRENT_VERSION=$(get_version)
    
    # Fix download URL: replace /latest/download/ with /download/vX.Y.Z/
    # This ensures each release points to its own assets, not the latest stable
    sed -i '' "s|/releases/latest/download/|/releases/download/v${CURRENT_VERSION}/|g" "${APPCAST_PATH}"
    log_info "Fixed download URL to point to v${CURRENT_VERSION}"
    
    # Add beta channel tag for beta versions
    if [[ "$CURRENT_VERSION" == *"-beta"* ]] || [[ "$CURRENT_VERSION" == *"-alpha"* ]] || [[ "$CURRENT_VERSION" == *"-rc"* ]]; then
        # Add <sparkle:channel>beta</sparkle:channel> after <sparkle:shortVersionString>
        sed -i '' 's|</sparkle:shortVersionString>|</sparkle:shortVersionString>\n            <sparkle:channel>beta</sparkle:channel>|g' "${APPCAST_PATH}"
        log_info "Added beta channel tag for pre-release version"
    fi
else
    log_error "Appcast generation failed"
    exit 1
fi
