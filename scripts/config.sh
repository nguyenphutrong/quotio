#!/bin/bash

# =============================================================================
# CKota Build Configuration
# =============================================================================

# Project settings
export PROJECT_NAME="CKota"
export SCHEME="CKota"
export BUNDLE_ID="proseek.io.vn.CKota"

# Paths
export PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export BUILD_DIR="${PROJECT_DIR}/build"
export ARCHIVE_PATH="${BUILD_DIR}/${PROJECT_NAME}.xcarchive"
export APP_PATH="${BUILD_DIR}/${PROJECT_NAME}.app"
export DMG_PATH="${BUILD_DIR}/${PROJECT_NAME}.dmg"
export RELEASE_DIR="${BUILD_DIR}/release"

# Code signing (set via environment or keychain)
export DEVELOPER_ID="${DEVELOPER_ID:-}"
export NOTARIZATION_KEYCHAIN_PROFILE="${NOTARIZATION_KEYCHAIN_PROFILE:-ckota-notarization}"

# GitHub
export GITHUB_REPO="synh/CKota"

# Sparkle
export SPARKLE_PRIVATE_KEY_PATH="${PROJECT_DIR}/.sparkle_private_key"
export APPCAST_PATH="${RELEASE_DIR}/appcast.xml"

# Colors for output
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export NC='\033[0m' # No Color

# Helper functions (log to stderr so stdout can be used for return values)
log_info() { echo -e "${GREEN}[INFO]${NC} $1" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1" >&2; }

check_command() {
    if ! command -v "$1" &> /dev/null; then
        log_error "$1 is required but not installed."
        exit 1
    fi
}

get_version() {
    local pbxproj="${PROJECT_DIR}/${PROJECT_NAME}.xcodeproj/project.pbxproj"
    grep -m1 "MARKETING_VERSION" "$pbxproj" | sed 's/.*= \(.*\);/\1/'
}

get_build_number() {
    local pbxproj="${PROJECT_DIR}/${PROJECT_NAME}.xcodeproj/project.pbxproj"
    grep -m1 "CURRENT_PROJECT_VERSION" "$pbxproj" | sed 's/.*= \(.*\);/\1/'
}
