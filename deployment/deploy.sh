#!/bin/bash
set -e

ENV=${1:-dev}
REGION=${2:-eu-central-1}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_ROOT"

# Load config from zvs.config.json
SERVICE_NAME=$(jq -r '.service' zvs.config.json)
FUNCTION_NAME=$(jq -r ".environments.${ENV}.functionName // empty" zvs.config.json)
ROLE_ARN=$(jq -r ".environments.${ENV}.roleArn // empty" zvs.config.json)
CONFIG_FILE=$(jq -r ".environments.${ENV}.configFile // empty" zvs.config.json)
RUNTIME=$(jq -r '.lambda.runtime' zvs.config.json)
HANDLER=$(jq -r '.lambda.handler' zvs.config.json)
S3_BUCKET=$(jq -r '.aws.s3Bucket // empty' zvs.config.json)
MEMORY_SIZE=$(jq -r ".environments.${ENV}.memorySize // .lambda.memorySize" zvs.config.json)
TIMEOUT=$(jq -r ".environments.${ENV}.timeout // .lambda.timeout" zvs.config.json)

ZIP_FILE="temp/${SERVICE_NAME}.zip"

# Build if needed
if [ ! -f "$ZIP_FILE" ]; then
  echo "Building package..."
  ./deployment/build.sh "$ENV"
fi

# Check if function exists
FUNCTION_EXISTS=$(aws lambda get-function \
  --function-name "$FUNCTION_NAME" \
  --region "$REGION" \
  --query 'Configuration.FunctionName' \
  --output text 2>/dev/null || echo "")

# Load environment variables
if [ -f "$CONFIG_FILE" ]; then
  ENV_VARS=$(cat "$CONFIG_FILE" | jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")')
else
  echo "Warning: Config file not found: $CONFIG_FILE"
  ENV_VARS=""
fi

if [ -n "$FUNCTION_EXISTS" ]; then
  echo "Updating existing function: $FUNCTION_NAME"

  # Check package size
  SIZE=$(stat -c%s "$ZIP_FILE" 2>/dev/null || stat -f%z "$ZIP_FILE" 2>/dev/null)
  SIZE_MB=$((SIZE / 1024 / 1024))

  if [ $SIZE_MB -gt 50 ] && [ -n "$S3_BUCKET" ]; then
    # Upload to S3 for large packages
    echo "Package size > 50MB, uploading to S3..."
    aws s3 cp "$ZIP_FILE" "s3://${S3_BUCKET}/${SERVICE_NAME}/${FUNCTION_NAME}.zip" --region "$REGION"
    aws lambda update-function-code \
      --function-name "$FUNCTION_NAME" \
      --s3-bucket "$S3_BUCKET" \
      --s3-key "${SERVICE_NAME}/${FUNCTION_NAME}.zip" \
      --region "$REGION"
  else
    # Direct upload
    aws lambda update-function-code \
      --function-name "$FUNCTION_NAME" \
      --zip-file "fileb://$ZIP_FILE" \
      --region "$REGION"
  fi

  aws lambda wait function-updated --function-name "$FUNCTION_NAME" --region "$REGION"

  # Update environment variables
  if [ -n "$ENV_VARS" ]; then
    echo "Updating environment variables..."
    ENV_JSON=$(cat "$CONFIG_FILE" | jq -r 'with_entries(.value |= tostring) | {Environment: {Variables: .}}')
    aws lambda update-function-configuration \
      --function-name "$FUNCTION_NAME" \
      --cli-input-json "$ENV_JSON" \
      --region "$REGION"
  fi

  echo "✅ Function updated"
else
  echo "Creating new function: $FUNCTION_NAME"

  # Build environment JSON for create-function
  if [ -f "$CONFIG_FILE" ]; then
    ENV_JSON=$(cat "$CONFIG_FILE" | jq -r 'with_entries(.value |= tostring) | {Environment: {Variables: .}}')
    aws lambda create-function \
      --function-name "$FUNCTION_NAME" \
      --runtime "$RUNTIME" \
      --role "$ROLE_ARN" \
      --handler "$HANDLER" \
      --zip-file "fileb://$ZIP_FILE" \
      --memory-size "$MEMORY_SIZE" \
      --timeout "$TIMEOUT" \
      --cli-input-json "$ENV_JSON" \
      --region "$REGION"
  else
    aws lambda create-function \
      --function-name "$FUNCTION_NAME" \
      --runtime "$RUNTIME" \
      --role "$ROLE_ARN" \
      --handler "$HANDLER" \
      --zip-file "fileb://$ZIP_FILE" \
      --memory-size "$MEMORY_SIZE" \
      --timeout "$TIMEOUT" \
      --region "$REGION"
  fi

  echo "✅ Function created"
fi

# Create/Get Function URL
echo "Checking Function URL..."
FUNCTION_URL=$(aws lambda get-function-url-config \
  --function-name "$FUNCTION_NAME" \
  --region "$REGION" \
  --query 'FunctionUrl' \
  --output text 2>/dev/null || echo "")

if [ -z "$FUNCTION_URL" ]; then
  echo "Creating Function URL..."
  FUNCTION_URL=$(aws lambda create-function-url-config \
    --function-name "$FUNCTION_NAME" \
    --region "$REGION" \
    --auth-type NONE \
    --invoke-mode RESPONSE_STREAM \
    --cors '{"AllowOrigins":["*"],"AllowMethods":["GET","POST","PUT","PATCH","DELETE"],"AllowHeaders":["*"]}' \
    --query 'FunctionUrl' \
    --output text)

  # Add permission for Function URL
  aws lambda add-permission \
    --function-name "$FUNCTION_NAME" \
    --statement-id "function-url-allow" \
    --action "lambda:InvokeFunctionUrl" \
    --principal "*" \
    --function-url-auth-type NONE \
    --region "$REGION" > /dev/null 2>&1 || true
fi

# Cleanup
rm -f "$ZIP_FILE"

# Manage API Gateway (create/delete based on config)
echo ""
./deployment/api-gateway.sh "$ENV" "$REGION"

echo ""
echo "========================================="
echo "Deployment Complete!"
echo "========================================="
echo "Function: $FUNCTION_NAME"
echo "Function URL: $FUNCTION_URL"
echo ""
