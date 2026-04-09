#!/bin/bash
set -e

ENV=${1:-dev}
REGION=${2:-eu-central-1}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SERVICE_NAME=$(jq -r '.service' "$PROJECT_ROOT/zvs.config.json")
LAYER_NAME="${SERVICE_NAME}-${ENV}-layer"

cd "$PROJECT_ROOT"

LAYER_ZIP="temp/layer-${SERVICE_NAME}.zip"
if [ ! -f "$LAYER_ZIP" ]; then
  echo "Layer not built. Building..."
  ./deployment/build-layer.sh "$ENV"
fi

# Check if layer exists
LAYER_EXISTS=$(aws lambda list-layers \
  --region "$REGION" \
  --query "Layers[?LayerName=='${LAYER_NAME}'].LayerName" \
  --output text 2>/dev/null || echo "")

LAYER_VERSION=$(aws lambda publish-layer-version \
  --layer-name "$LAYER_NAME" \
  --description "Dependencies for ${SERVICE_NAME}" \
  --compatible-runtimes nodejs18.x \
  --zip-file "fileb://$LAYER_ZIP" \
  --region "$REGION" \
  --query 'Version' \
  --output text)

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
LAYER_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:layer:${LAYER_NAME}:${LAYER_VERSION}"

# Clean old versions (keep latest 3)
VERSIONS_TO_DELETE=$(aws lambda list-layer-versions \
  --layer-name "$LAYER_NAME" \
  --region "$REGION" \
  --query "sort(LayerVersions[*].Version, &(@))[:-3]" \
  --output text)

for VERSION in $VERSIONS_TO_DELETE; do
  aws lambda delete-layer-version \
    --layer-name "$LAYER_NAME" \
    --version-number "$VERSION" \
    --region "$REGION" 2>/dev/null || true
done

echo "✅ Layer deployed: $LAYER_ARN"
echo ""
echo "Add to your zvs.config.json lambda.layers:"
echo "\"$LAYER_ARN\""
