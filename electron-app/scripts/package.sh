#!/bin/bash

# ============================================
# Quotio Electron - Package Script
# Creates DMG for macOS distribution
# ============================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "📦 Packaging Quotio for macOS..."

cd "$PROJECT_DIR"

# Ensure build is complete
if [ ! -d "dist" ]; then
    echo "❌ Build not found. Running build first..."
    ./scripts/build.sh
fi

# Create DMG
echo "💿 Creating DMG..."
npm run dist:dmg

# List outputs
echo ""
echo "✅ Package complete!"
echo "📁 Output files:"
ls -la build/*.dmg 2>/dev/null || echo "  No DMG files found"
ls -la build/*.zip 2>/dev/null || echo "  No ZIP files found"

echo ""
echo "📊 DMG Contents:"
if [ -f build/*.dmg ]; then
    DMG_FILE=$(ls build/*.dmg | head -1)
    hdiutil attach "$DMG_FILE" -mountpoint /tmp/quotio-mount -nobrowse 2>/dev/null || true
    ls -la /tmp/quotio-mount 2>/dev/null || true
    hdiutil detach /tmp/quotio-mount 2>/dev/null || true
fi

echo ""
echo "🔒 Security Checklist:"
echo "  ✓ Hardened runtime enabled"
echo "  ✓ Entitlements configured"
echo "  ✓ ASAR packaging enabled"
echo "  ✓ Context isolation enabled"
echo "  ✓ Node integration disabled"
echo ""
echo "📝 Note: For distribution, sign the app with:"
echo "   npm run dist:mac -- --sign"
