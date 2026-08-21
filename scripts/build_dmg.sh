#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_NAME="Quotio"
GITHUB_REPO="nguyenphutrong/quotio"
PROJECT_FILE="${PROJECT_DIR}/${PROJECT_NAME}.xcodeproj"
PBXPROJ="${PROJECT_FILE}/project.pbxproj"
CHANGELOG="${PROJECT_DIR}/CHANGELOG.md"
BUILD_DIR="${PROJECT_DIR}/build"
APP_PATH="${BUILD_DIR}/${PROJECT_NAME}.app"
RELEASE_DIR="${BUILD_DIR}/release"
APPCAST_PATH="${RELEASE_DIR}/appcast.xml"
RELEASE_VERSION=""
GENERATE_APPCAST=false
DISTRIBUTION=false
SIGN_UPDATE=""
TEMP_ROOT=""
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application}"
NOTARYTOOL_KEYCHAIN_PROFILE="${NOTARYTOOL_KEYCHAIN_PROFILE:-}"
NOTARYTOOL_KEYCHAIN="${NOTARYTOOL_KEYCHAIN:-}"
NOTARYTOOL_AUTH_ARGS=()

usage() {
    echo "Usage: $0 [--version VERSION] [--distribution] [--generate-appcast]"
    echo ""
    echo "Build the Release app and create DMG and ZIP artifacts."
    echo "  --version VERSION      update the Xcode version and CHANGELOG before building"
    echo "  --distribution         require Developer ID signing and Apple notarization"
    echo "  --generate-appcast     sign the ZIP and create appcast.xml using SPARKLE_PRIVATE_KEY"
}

log() {
    echo "==> $1"
}

fail() {
    echo "error: $1" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

read_build_setting() {
    grep -m1 "$1 = " "${PBXPROJ}" | sed 's/.*= \([^;]*\);/\1/'
}

prepare_release_version() {
    local version="$1"
    local current_version
    local current_build
    local next_build

    [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]] \
        || fail "invalid version: ${version}"

    if ! grep -Fq "## [${version}]" "${CHANGELOG}"; then
        sed -i '' "s/## \[Unreleased\]/## [Unreleased]\n\n## [${version}] - $(date +%Y-%m-%d)/" "${CHANGELOG}"
        grep -Fq "## [${version}]" "${CHANGELOG}" \
            || fail "failed to add ${version} to CHANGELOG.md"
        log "Added ${version} to CHANGELOG.md"
    fi

    current_version="$(read_build_setting MARKETING_VERSION)"
    current_build="$(read_build_setting CURRENT_PROJECT_VERSION)"
    [ -n "${current_version}" ] || fail "MARKETING_VERSION not found"
    [[ "${current_build}" =~ ^[0-9]+$ ]] || fail "CURRENT_PROJECT_VERSION is not numeric"

    if [ "${version}" = "${current_version}" ]; then
        log "Xcode project is already at ${version} (build ${current_build})"
        return
    fi

    next_build=$((current_build + 1))
    sed -i '' "s/MARKETING_VERSION = ${current_version}/MARKETING_VERSION = ${version}/g" "${PBXPROJ}"
    sed -i '' "s/CURRENT_PROJECT_VERSION = ${current_build}/CURRENT_PROJECT_VERSION = ${next_build}/g" "${PBXPROJ}"

    [ "$(read_build_setting MARKETING_VERSION)" = "${version}" ] \
        || fail "failed to update MARKETING_VERSION"
    [ "$(read_build_setting CURRENT_PROJECT_VERSION)" = "${next_build}" ] \
        || fail "failed to update CURRENT_PROJECT_VERSION"

    log "Updated Xcode project to ${version} (build ${next_build})"
}

configure_distribution() {
    [ -n "${NOTARYTOOL_KEYCHAIN_PROFILE}" ] \
        || fail "NOTARYTOOL_KEYCHAIN_PROFILE is required for --distribution"

    NOTARYTOOL_AUTH_ARGS=(--keychain-profile "${NOTARYTOOL_KEYCHAIN_PROFILE}")
    if [ -n "${NOTARYTOOL_KEYCHAIN}" ]; then
        NOTARYTOOL_AUTH_ARGS+=(--keychain "${NOTARYTOOL_KEYCHAIN}")
    fi

    security find-identity -v -p codesigning | grep -F "${SIGNING_IDENTITY}" >/dev/null \
        || fail "code-signing identity not found: ${SIGNING_IDENTITY}"
}

sign_macho_files() {
    local binary_path

    while IFS= read -r binary_path; do
        if file "${binary_path}" | grep -q "Mach-O"; then
            codesign \
                --force \
                --sign "${SIGNING_IDENTITY}" \
                --options runtime \
                --timestamp \
                --preserve-metadata=identifier,entitlements \
                "${binary_path}"
        fi
    done < <(find "${APP_PATH}/Contents" -type f)
}

sign_nested_code_bundles() {
    local code_path

    while IFS= read -r code_path; do
        codesign \
            --force \
            --sign "${SIGNING_IDENTITY}" \
            --options runtime \
            --timestamp \
            --preserve-metadata=identifier,entitlements \
            "${code_path}"
    done < <(
        find "${APP_PATH}/Contents" -type d \( \
            -name "*.framework" -o \
            -name "*.xpc" -o \
            -name "*.appex" -o \
            -name "*.app" \
        \) \
            | awk '{ print gsub("/", "/"), $0 }' \
            | sort -rn \
            | cut -d' ' -f2-
    )
}

sign_app_for_distribution() {
    local team_identifier

    log "Signing nested code with Developer ID"
    sign_macho_files
    sign_nested_code_bundles

    codesign \
        --force \
        --sign "${SIGNING_IDENTITY}" \
        --options runtime \
        --timestamp \
        --entitlements "${PROJECT_DIR}/Quotio/Quotio.entitlements" \
        "${APP_PATH}"
    codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

    team_identifier="$(
        codesign -dv --verbose=4 "${APP_PATH}" 2>&1 \
            | sed -n 's/^TeamIdentifier=//p' \
            | head -n 1
    )"
    [ -n "${team_identifier}" ] && [ "${team_identifier}" != "not set" ] \
        || fail "Developer ID signature has no TeamIdentifier"
    log "Signed app with TeamIdentifier ${team_identifier}"
}

notarize_app() {
    local submission_zip="${TEMP_ROOT}/${PROJECT_NAME}-notarization.zip"

    log "Submitting app for notarization"
    ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${submission_zip}"
    xcrun notarytool submit "${submission_zip}" "${NOTARYTOOL_AUTH_ARGS[@]}" --wait
    xcrun stapler staple "${APP_PATH}"
    xcrun stapler validate "${APP_PATH}"
    spctl --assess --type execute --verbose=2 "${APP_PATH}"
}

notarize_dmg() {
    local dmg_file="$1"

    log "Signing and notarizing ${dmg_file}"
    codesign --force --sign "${SIGNING_IDENTITY}" --timestamp "${dmg_file}"
    codesign --verify --strict --verbose=2 "${dmg_file}"
    xcrun notarytool submit "${dmg_file}" "${NOTARYTOOL_AUTH_ARGS[@]}" --wait
    xcrun stapler staple "${dmg_file}"
    xcrun stapler validate "${dmg_file}"
    spctl \
        --assess \
        --type open \
        --context context:primary-signature \
        --verbose=2 \
        "${dmg_file}"
}

install_sparkle_tools() {
    local sparkle_dir="${PROJECT_DIR}/.sparkle"
    local sparkle_version="2.8.1"
    local sparkle_url="https://github.com/sparkle-project/Sparkle/releases/download/${sparkle_version}/Sparkle-${sparkle_version}.tar.xz"

    SIGN_UPDATE="${sparkle_dir}/bin/sign_update"
    if [ -x "${SIGN_UPDATE}" ]; then
        return
    fi

    log "Downloading Sparkle ${sparkle_version} tools"
    mkdir -p "${sparkle_dir}"
    curl -fsSL "${sparkle_url}" | tar xJ -C "${sparkle_dir}"
    [ -x "${SIGN_UPDATE}" ] || fail "Sparkle sign_update was not installed"
}

generate_appcast() {
    local version="$1"
    local build_number="$2"
    local zip_file="$3"
    local zip_name
    local zip_size
    local sign_output
    local signature
    local channel=""
    local existing_appcast
    local existing_items=""
    local new_item

    [ -n "${SPARKLE_PRIVATE_KEY:-}" ] || fail "SPARKLE_PRIVATE_KEY is required for appcast generation"
    require_command curl
    require_command tar
    install_sparkle_tools

    log "Signing ${zip_file} for Sparkle"
    sign_output="$(printf '%s\n' "${SPARKLE_PRIVATE_KEY}" | "${SIGN_UPDATE}" --ed-key-file - "${zip_file}" 2>/dev/null)"
    signature="$(printf '%s\n' "${sign_output}" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' | head -n 1)"
    [ -n "${signature}" ] || fail "Sparkle did not return an EdDSA signature"

    zip_name="$(basename "${zip_file}")"
    zip_size="$(stat -f%z "${zip_file}")"
    case "${version}" in
        *-alpha*|*-beta*|*-rc*) channel="            <sparkle:channel>beta</sparkle:channel>" ;;
    esac

    new_item="        <item>
            <title>Version ${version}</title>
            <sparkle:version>${build_number}</sparkle:version>
            <sparkle:shortVersionString>${version}</sparkle:shortVersionString>"
    if [ -n "${channel}" ]; then
        new_item="${new_item}
${channel}"
    fi
    new_item="${new_item}
            <pubDate>$(date -R)</pubDate>
            <enclosure url=\"https://github.com/${GITHUB_REPO}/releases/download/v${version}/${zip_name}\"
                       sparkle:edSignature=\"${signature}\"
                       length=\"${zip_size}\"
                       type=\"application/octet-stream\"/>
        </item>"

    existing_appcast="$(curl -fsSL "https://github.com/${GITHUB_REPO}/releases/latest/download/appcast.xml" 2>/dev/null || true)"
    if [[ "${existing_appcast}" == *"<item>"* ]]; then
        existing_items="$(
            printf '%s\n' "${existing_appcast}" \
                | sed -n '/<item>/,/<\/item>/p' \
                | awk -v version="${version}" '
                    /<item>/ { item = ""; in_item = 1 }
                    in_item { item = item $0 "\n" }
                    /<\/item>/ {
                        in_item = 0
                        if (index(item, ">" version "<") == 0) printf "%s", item
                    }
                '
        )"
    fi

    cat > "${APPCAST_PATH}" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>${PROJECT_NAME}</title>
        <link>https://github.com/${GITHUB_REPO}</link>
        <description>Most recent changes with links to updates.</description>
        <language>en</language>
${new_item}
${existing_items}
    </channel>
</rss>
EOF
    log "Created ${APPCAST_PATH}"
}

cleanup() {
    if [ -n "${TEMP_ROOT}" ]; then
        rm -rf "${TEMP_ROOT}"
    fi
}
trap cleanup EXIT

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version)
            [ "$#" -ge 2 ] || fail "--version requires a value"
            RELEASE_VERSION="$2"
            shift 2
            ;;
        --generate-appcast)
            GENERATE_APPCAST=true
            shift
            ;;
        --distribution)
            DISTRIBUTION=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            fail "unknown option: $1"
            ;;
    esac
done

require_command xcodebuild
require_command ditto
require_command codesign
require_command shasum
require_command hdiutil

if [ "${DISTRIBUTION}" = true ]; then
    require_command security
    require_command file
    require_command xcrun
    require_command spctl
    configure_distribution
fi

if [ -n "${RELEASE_VERSION}" ]; then
    prepare_release_version "${RELEASE_VERSION}"
fi

VERSION="$(read_build_setting MARKETING_VERSION)"
BUILD_NUMBER="$(read_build_setting CURRENT_PROJECT_VERSION)"
[ -n "${VERSION}" ] || fail "MARKETING_VERSION not found"
[ -n "${BUILD_NUMBER}" ] || fail "CURRENT_PROJECT_VERSION not found"

log "Building ${PROJECT_NAME} ${VERSION} (build ${BUILD_NUMBER})"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/quotio-release.XXXXXX")"
ARCHIVE_PATH="${TEMP_ROOT}/${PROJECT_NAME}.xcarchive"
DERIVED_DATA="${TEMP_ROOT}/DerivedData"
DMG_STAGING="${TEMP_ROOT}/dmg-staging"

rm -rf "${APP_PATH}" "${RELEASE_DIR}"
mkdir -p "${BUILD_DIR}" "${RELEASE_DIR}"

ARCHIVE_ARGS=(
    archive
    -project "${PROJECT_FILE}"
    -scheme "${PROJECT_NAME}"
    -configuration Release
    -archivePath "${ARCHIVE_PATH}"
    -derivedDataPath "${DERIVED_DATA}"
    -destination "generic/platform=macOS"
    SKIP_INSTALL=NO
    BUILD_LIBRARY_FOR_DISTRIBUTION=YES
    CODE_SIGN_IDENTITY="-"
    CODE_SIGNING_REQUIRED=NO
    CODE_SIGNING_ALLOWED=NO
)
if [ -n "${POSTHOG_PROJECT_TOKEN:-}" ]; then
    ARCHIVE_ARGS+=("POSTHOG_PROJECT_TOKEN=${POSTHOG_PROJECT_TOKEN}")
fi
if [ -n "${POSTHOG_HOST:-}" ]; then
    ARCHIVE_ARGS+=("POSTHOG_HOST=${POSTHOG_HOST}")
fi

xcodebuild "${ARCHIVE_ARGS[@]}" 2>&1 | tee "${BUILD_DIR}/release-build.log"

ARCHIVED_APP="${ARCHIVE_PATH}/Products/Applications/${PROJECT_NAME}.app"
[ -d "${ARCHIVED_APP}" ] || fail "archive did not contain ${PROJECT_NAME}.app"
cp -R "${ARCHIVED_APP}" "${APP_PATH}"
if [ "${DISTRIBUTION}" = true ]; then
    sign_app_for_distribution
    notarize_app
else
    codesign --force --deep --sign - "${APP_PATH}"
fi

ZIP_FILE="${RELEASE_DIR}/${PROJECT_NAME}-${VERSION}.zip"
DMG_FILE="${RELEASE_DIR}/${PROJECT_NAME}-${VERSION}.dmg"
log "Creating ${ZIP_FILE}"
ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${ZIP_FILE}"

mkdir -p "${DMG_STAGING}"
cp -R "${APP_PATH}" "${DMG_STAGING}/"

log "Creating ${DMG_FILE}"
if command -v create-dmg >/dev/null 2>&1; then
    if ! create-dmg \
        --volname "${PROJECT_NAME}" \
        --window-pos 200 120 \
        --window-size 600 400 \
        --icon-size 100 \
        --icon "${PROJECT_NAME}.app" 150 190 \
        --hide-extension "${PROJECT_NAME}.app" \
        --app-drop-link 450 185 \
        --no-internet-enable \
        "${DMG_FILE}" \
        "${DMG_STAGING}"; then
        [ -f "${DMG_FILE}" ] || fail "create-dmg failed"
    fi
else
    hdiutil create \
        -volname "${PROJECT_NAME}" \
        -srcfolder "${DMG_STAGING}" \
        -ov \
        -format UDZO \
        "${DMG_FILE}"
fi

[ -f "${ZIP_FILE}" ] || fail "ZIP artifact was not created"
[ -f "${DMG_FILE}" ] || fail "DMG artifact was not created"

if [ "${DISTRIBUTION}" = true ]; then
    notarize_dmg "${DMG_FILE}"
fi

if [ "${GENERATE_APPCAST}" = true ]; then
    generate_appcast "${VERSION}" "${BUILD_NUMBER}" "${ZIP_FILE}"
fi

log "DMG: ${DMG_FILE}"
log "ZIP: ${ZIP_FILE}"
