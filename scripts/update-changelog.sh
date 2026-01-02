#!/bin/bash
set -e

# =============================================================================
# Update CHANGELOG
# Auto-move [Unreleased] content to versioned section if not exists
# Usage: ./update-changelog.sh VERSION
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

VERSION="${1:-}"
CHANGELOG="${PROJECT_DIR}/CHANGELOG.md"
TODAY=$(date +%Y-%m-%d)

if [ -z "$VERSION" ]; then
    log_error "Usage: $0 VERSION"
    exit 1
fi

if [ ! -f "$CHANGELOG" ]; then
    log_error "CHANGELOG.md not found"
    exit 1
fi

# Check if version section already exists
if grep -q "## \[${VERSION}\]" "$CHANGELOG"; then
    log_info "CHANGELOG already has section for [${VERSION}]"
    exit 0
fi

# Check if [Unreleased] section has content
UNRELEASED_CONTENT=$(awk '/^## \[Unreleased\]/{flag=1; next} /^## \[/{flag=0} flag' "$CHANGELOG" | grep -v '^$' | head -1)

if [ -z "$UNRELEASED_CONTENT" ]; then
    log_warn "[Unreleased] section is empty. Creating empty version section."
    sed -i '' "s/## \[Unreleased\]/## [Unreleased]\n\n## [${VERSION}] - ${TODAY}/" "$CHANGELOG"
else
    log_info "Moving [Unreleased] content to [${VERSION}] - ${TODAY}"
    sed -i '' "s/## \[Unreleased\]/## [Unreleased]\n\n## [${VERSION}] - ${TODAY}/" "$CHANGELOG"
fi

log_info "CHANGELOG updated successfully"
