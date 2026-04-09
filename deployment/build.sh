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

# Generate Prisma client (if using Prisma)
if [ -f "prisma/schema.prisma" ]; then
  echo "Generating Prisma client..."
  npx prisma generate
fi

# Build TypeScript
echo "Compiling TypeScript..."
npx tsc -p tsconfig.build.json

# Create build directory (app code only, no node_modules)
mkdir -p build
cp -r dist/* build/
cp package.json package-lock.json build/

# Copy generated Prisma client (needed for enums) - only if Prisma is used
if [ -d "node_modules/@prisma/client" ]; then
  mkdir -p build/node_modules/@prisma
  # Copy the base Prisma client package with runtime first
  cp -r node_modules/@prisma/client build/node_modules/@prisma/
  # Then copy generated files (index.js, etc.) from .prisma/client
  cp -r node_modules/.prisma/client/* build/node_modules/@prisma/client/
fi

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
