#!/bin/bash

# ============================================
# Quotio Electron - Build Script
# ============================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "🔨 Building Quotio Electron..."

cd "$PROJECT_DIR"

# Clean previous builds
echo "🧹 Cleaning previous builds..."
rm -rf dist build

# Install dependencies
echo "📦 Installing dependencies..."
npm ci

# Run linting
echo "🔍 Running linter..."
npm run lint || echo "⚠️ Lint warnings found, continuing..."

# Run type checking
echo "📝 Type checking..."
npm run typecheck || echo "⚠️ Type errors found, continuing..."

# Build the application
echo "🏗️ Building application..."
npm run build

echo "✅ Build complete!"
echo "📁 Output in dist/"
