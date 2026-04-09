#!/bin/bash
set -e

ENV=${1:-dev}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SERVICE_NAME=$(jq -r '.service' "$PROJECT_ROOT/zvs.config.json")

cd "$PROJECT_ROOT"

LAYER_DIR="temp/layer/nodejs"
rm -rf temp/layer
mkdir -p "$LAYER_DIR"

echo "Building Lambda layer for $SERVICE_NAME..."

# Create minimal package.json for layer
cat > "$LAYER_DIR/package.json" << 'EOF'
{
  "name": "lambda-layer",
  "version": "1.0.0",
  "description": "Lambda dependencies layer",
  "private": true
}
EOF

cd "$LAYER_DIR"

# Install production dependencies
npm install --production --no-package-lock

# Aggressive cleanup (from RO_api)
rm -rf node_modules/**/*.md
rm -rf node_modules/**/*.test.js
rm -rf node_modules/**/*.spec.js
rm -rf node_modules/**/README*
rm -rf node_modules/**/LICENSE*
rm -rf node_modules/**/CHANGELOG*
rm -rf node_modules/**/docs
rm -rf node_modules/**/examples
rm -rf node_modules/.package-lock.json
find node_modules -name "*.map" -delete 2>/dev/null || true

# Create layer ZIP
cd "$PROJECT_ROOT/temp"
zip -qr9 "layer-${SERVICE_NAME}.zip" -C layer/nodejs node_modules

# Cleanup
rm -rf layer

SIZE=$(stat -c%s "layer-${SERVICE_NAME}.zip" 2>/dev/null || stat -f%z "layer-${SERVICE_NAME}.zip" 2>/dev/null)
SIZE_MB=$((SIZE / 1024 / 1024))
echo "✅ Layer built: temp/layer-${SERVICE_NAME}.zip (${SIZE_MB} MB)"
