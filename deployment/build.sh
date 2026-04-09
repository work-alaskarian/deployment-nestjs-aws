#!/bin/bash
set -e

ENV=${1:-dev}
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

# Load config
SERVICE_NAME=$(jq -r '.service' zvs.config.json)
ZIP_FILE="temp/${SERVICE_NAME}.zip"

# Clean
rm -rf dist build temp

# Build TypeScript
echo "Compiling TypeScript..."
npx tsc -p tsconfig.build.json

# Create build directory
mkdir -p build
cp -r dist/* build/
cp lambda.js build/
cp package.json package-lock.json build/

# Install production dependencies (for Lambda without layers)
cd build
npm ci --only=production --no-package-lock

# Aggressive cleanup to reduce size
rm -rf node_modules/**/*.md
rm -rf node_modules/**/*.test.js
rm -rf node_modules/**/*.spec.js
rm -rf node_modules/**/README*
rm -rf node_modules/**/LICENSE*
rm -rf node_modules/**/CHANGELOG*
rm -rf node_modules/**/docs
rm -rf node_modules/**/examples
find node_modules -name "*.map" -delete 2>/dev/null || true
cd ..

# Create ZIP with max compression
mkdir -p temp
echo "Creating ZIP package..."
(cd build && zip -qr9 ../temp/${SERVICE_NAME}.zip .)

# Cleanup
rm -rf build dist

# Report size
SIZE=$(stat -c%s "$ZIP_FILE" 2>/dev/null || stat -f%z "$ZIP_FILE" 2>/dev/null)
if [ $SIZE -gt 1048576 ]; then
  SIZE_MB=$((SIZE / 1024 / 1024))
  echo "✅ Build complete: ${ZIP_FILE} (${SIZE_MB} MB)"
else
  SIZE_KB=$((SIZE / 1024))
  echo "✅ Build complete: ${ZIP_FILE} (${SIZE_KB} KB)"
fi
