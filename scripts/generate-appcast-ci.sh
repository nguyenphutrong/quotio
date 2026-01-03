#!/bin/bash
set -e

# =============================================================================
# Generate Sparkle Appcast for CI
# Uses SPARKLE_PRIVATE_KEY environment variable instead of Keychain
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

log_info "Generating appcast for CI..."

SPARKLE_DIR="${PROJECT_DIR}/.sparkle"
SPARKLE_BIN="${SPARKLE_DIR}/bin"
GENERATE_APPCAST="${SPARKLE_BIN}/generate_appcast"
SIGN_UPDATE="${SPARKLE_BIN}/sign_update"

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
    exit 1
fi

# Check for Sparkle private key
if [ -z "$SPARKLE_PRIVATE_KEY" ]; then
    log_error "SPARKLE_PRIVATE_KEY environment variable not set"
    exit 1
fi

# Get current version and build number
CURRENT_VERSION=$(get_version)
BUILD_NUMBER=$(get_build_number)
log_info "Generating appcast for version ${CURRENT_VERSION} (build ${BUILD_NUMBER})"

# Temporarily move DMG files to avoid Sparkle duplicate version error
DMG_FILES=$(find "$RELEASE_DIR" -name "*.dmg" -type f 2>/dev/null)
TEMP_DMG_DIR="${BUILD_DIR}/dmg_temp"
if [ -n "$DMG_FILES" ]; then
    mkdir -p "$TEMP_DMG_DIR"
    for dmg in $DMG_FILES; do
        mv "$dmg" "$TEMP_DMG_DIR/"
    done
    log_info "Temporarily moved DMG files for appcast generation"
fi

# Find ZIP file and sign it manually
ZIP_FILE=$(find "$RELEASE_DIR" -name "*.zip" -type f | head -1)
if [ -z "$ZIP_FILE" ]; then
    log_error "No ZIP file found in ${RELEASE_DIR}"
    exit 1
fi

log_step "Signing ZIP file with Sparkle..."
SIGNATURE=$(echo "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - "$ZIP_FILE" 2>/dev/null | grep "sparkle:edSignature" | sed 's/.*sparkle:edSignature="\([^"]*\)".*/\1/')

if [ -z "$SIGNATURE" ]; then
    log_error "Failed to generate signature"
    exit 1
fi

log_info "Generated signature: ${SIGNATURE:0:20}..."

# Get file info
ZIP_SIZE=$(stat -f%z "$ZIP_FILE")
ZIP_NAME=$(basename "$ZIP_FILE")

# Generate appcast XML manually
# Determine if this is a beta release
IS_BETA=false
if [[ "$CURRENT_VERSION" == *"-beta"* ]] || [[ "$CURRENT_VERSION" == *"-alpha"* ]] || [[ "$CURRENT_VERSION" == *"-rc"* ]]; then
    IS_BETA=true
fi

# Build the new item entry
NEW_ITEM="        <item>
            <title>Version ${CURRENT_VERSION}</title>
            <sparkle:version>${BUILD_NUMBER}</sparkle:version>
            <sparkle:shortVersionString>${CURRENT_VERSION}</sparkle:shortVersionString>"

if [[ "$IS_BETA" == true ]]; then
    NEW_ITEM="${NEW_ITEM}
            <sparkle:channel>beta</sparkle:channel>"
fi

NEW_ITEM="${NEW_ITEM}
            <pubDate>$(date -R)</pubDate>
            <enclosure url=\"https://github.com/${GITHUB_REPO}/releases/download/v${CURRENT_VERSION}/${ZIP_NAME}\"
                       sparkle:edSignature=\"${SIGNATURE}\"
                       length=\"${ZIP_SIZE}\"
                       type=\"application/octet-stream\"/>
        </item>"

log_step "Generating appcast.xml..."

# Try to fetch existing appcast from latest stable release
EXISTING_APPCAST_URL="https://github.com/${GITHUB_REPO}/releases/latest/download/appcast.xml"
EXISTING_ITEMS=""

log_step "Fetching existing appcast from latest release..."
EXISTING_APPCAST=$(curl -sL "$EXISTING_APPCAST_URL" 2>/dev/null || echo "")

if [[ -n "$EXISTING_APPCAST" ]] && [[ "$EXISTING_APPCAST" == *"<item>"* ]]; then
    log_info "Found existing appcast, merging entries..."
    # Extract existing items (everything between <item> and </item>)
    EXISTING_ITEMS=$(echo "$EXISTING_APPCAST" | sed -n '/<item>/,/<\/item>/p')
    
    # Remove any existing entry with the same version to avoid duplicates
    EXISTING_ITEMS=$(echo "$EXISTING_ITEMS" | awk -v ver="$CURRENT_VERSION" '
        BEGIN { skip=0 }
        /<item>/ { 
            item=""
            in_item=1
        }
        in_item { item = item $0 "\n" }
        /<\/item>/ {
            in_item=0
            if (item !~ ">" ver "<") {
                printf "%s", item
            }
        }
    ')
else
    log_info "No existing appcast found, creating fresh one"
fi

# Create the merged appcast
cat > "${APPCAST_PATH}" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>${PROJECT_NAME}</title>
        <link>https://github.com/${GITHUB_REPO}</link>
        <description>Most recent changes with links to updates.</description>
        <language>en</language>
${NEW_ITEM}
${EXISTING_ITEMS}
    </channel>
</rss>
EOF

if [[ "$IS_BETA" == true ]]; then
    log_info "Added beta channel tag for pre-release version"
fi

# Restore DMG files
if [ -d "$TEMP_DMG_DIR" ] && [ -n "$(ls -A "$TEMP_DMG_DIR" 2>/dev/null)" ]; then
    mv "$TEMP_DMG_DIR"/*.dmg "$RELEASE_DIR/"
    rmdir "$TEMP_DMG_DIR"
    log_info "Restored DMG files"
fi

if [ -f "${APPCAST_PATH}" ]; then
    log_info "Appcast generated: ${APPCAST_PATH}"
    cat "${APPCAST_PATH}"
else
    log_error "Appcast generation failed"
    exit 1
fi
