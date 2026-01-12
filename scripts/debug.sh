#!/bin/bash
set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
PROJECT_NAME="Quotio"
SCHEME="Quotio"
BUILD_DIR="${PROJECT_DIR}/build"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  ${PROJECT_NAME} Debug Build & Launch${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Step 1: Build
echo -e "${BLUE}[1/2]${NC} Building Debug configuration..."

xcodebuild \
    -project "${PROJECT_DIR}/${PROJECT_NAME}.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration Debug \
    -derivedDataPath "${BUILD_DIR}/DerivedData" \
    build \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    2>&1 | while read -r line; do
        if [[ "$line" == *"error:"* ]]; then
            echo -e "  ${RED}✗ ${line}${NC}"
        elif [[ "$line" == *"warning:"* ]]; then
            echo -e "  ${YELLOW}⚠ ${line}${NC}"
        elif [[ "$line" == "** BUILD SUCCEEDED **" ]]; then
            echo -e "  ${GREEN}✓ Build succeeded${NC}"
        elif [[ "$line" == "** BUILD FAILED **" ]]; then
            echo -e "  ${RED}✗ Build failed${NC}"
        fi
    done

# Find the built app
APP_PATH=$(find "${BUILD_DIR}/DerivedData" -name "${PROJECT_NAME}.app" -type d | head -n 1)

if [ -z "$APP_PATH" ]; then
    echo -e "${RED}✗ Failed to find built app${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Built app: ${APP_PATH}${NC}"
echo ""

# Step 2: Launch
echo -e "${BLUE}[2/2]${NC} Launching ${PROJECT_NAME}..."

# Kill existing instances
pkill -9 "${PROJECT_NAME}" 2>/dev/null || true
sleep 0.5

# Launch the app
open "${APP_PATH}"

echo -e "${GREEN}✓ ${PROJECT_NAME} launched successfully${NC}"
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Done!${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
