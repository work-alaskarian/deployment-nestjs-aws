#!/bin/bash
set -e

ENV=${1:-dev}
REGION=${2:-eu-central-1}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_ROOT"

# Load config
SERVICE_NAME=$(jq -r '.service' zvs.config.json)
FUNCTION_NAME=$(jq -r ".environments.${ENV}.functionName" zvs.config.json)
API_GATEWAY_ENABLED=$(jq -r ".environments.${ENV}.apiGateway.enabled // .apiGateway.enabled // false" zvs.config.json)
STAGE_NAME=$(jq -r ".environments.${ENV}.apiGateway.stageName // .apiGateway.stageName // \"${ENV}\"" zvs.config.json)
API_DESCRIPTION=$(jq -r ".environments.${ENV}.apiGateway.description // .apiGateway.description // \"API Gateway for ${SERVICE_NAME} (${ENV})\"" zvs.config.json)
API_PREFIX=$(jq -r '.lambda.apiPrefix // "/api/v1"' zvs.config.json)
API_NAME="${SERVICE_NAME}-${ENV}"

echo "========================================="
echo "API Gateway Management"
echo "========================================="
echo "Service: $SERVICE_NAME"
echo "Environment: $ENV"
echo "API Gateway Enabled: $API_GATEWAY_ENABLED"
echo ""

# Check if API Gateway exists
API_ID=$(aws apigateway get-rest-apis --region "$REGION" --query "items[?name=='$API_NAME'].id" --output text 2>/dev/null || echo "")

# If API Gateway is disabled, delete existing if found
if [ "$API_GATEWAY_ENABLED" != "true" ]; then
  echo "API Gateway is DISABLED for $ENV"
  if [ -n "$API_ID" ]; then
    echo "Deleting existing API Gateway: $API_ID..."
    aws apigateway delete-rest-api --rest-api-id "$API_ID" --region "$REGION" 2>/dev/null || true
    echo "✅ API Gateway deleted"
  else
    echo "No existing API Gateway to delete"
  fi
  echo ""
  exit 0
fi

# API Gateway is enabled - create or update
echo "API Gateway is ENABLED for $ENV"

# Create API Gateway if needed
if [ -z "$API_ID" ]; then
  echo "Creating new API Gateway: $API_NAME"
  API_ID=$(aws apigateway create-rest-api \
    --name "$API_NAME" \
    --description "$API_DESCRIPTION" \
    --region "$REGION" \
    --query 'id' --output text)

  echo "✅ API Gateway created: $API_ID"
else
  echo "Using existing API Gateway: $API_ID"
fi

# Get root resource id
ROOT_ID=$(aws apigateway get-resources --rest-api-id "$API_ID" --region "$REGION" --query 'items[?path==`/`].id' --output text)

# Build API prefix path (remove leading slash for AWS CLI)
API_PREFIX_PATH=$(echo "$API_PREFIX" | sed 's|^/||')

# Create resource structure for /api/prefix/{proxy+}
echo "Setting up resources..."

# Split API_PREFIX_PATH by / and create nested resources
CURRENT_PARENT_ID="$ROOT_ID"
IFS='/' read -ra PATH_PARTS <<< "$API_PREFIX_PATH"

for PART in "${PATH_PARTS[@]}"; do
  if [ -n "$PART" ]; then
    # Check if this resource already exists
    EXISTING_RESOURCE_ID=$(aws apigateway get-resources \
      --rest-api-id "$API_ID" \
      --region "$REGION" \
      --query "items[?pathPart=='$PART' && parentId=='$CURRENT_PARENT_ID'].id" \
      --output text 2>/dev/null || echo "")

    if [ -z "$EXISTING_RESOURCE_ID" ]; then
      CURRENT_PARENT_ID=$(aws apigateway create-resource \
        --rest-api-id "$API_ID" \
        --parent-id "$CURRENT_PARENT_ID" \
        --path-part "$PART" \
        --region "$REGION" \
        --query 'id' --output text)
    else
      CURRENT_PARENT_ID="$EXISTING_RESOURCE_ID"
    fi
  fi
done

# Create proxy resource
PROXY_RESOURCE_ID=$(aws apigateway create-resource \
  --rest-api-id "$API_ID" \
  --parent-id "$CURRENT_PARENT_ID" \
  --path-part "{proxy+}" \
  --region "$REGION" \
  --query 'id' --output text)

echo "✅ Resources created: /${API_PREFIX_PATH}/{proxy+}"

# Get Lambda region and account for integration
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
LAMBDA_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${FUNCTION_NAME}"
LAMBDA_URI="arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/${LAMBDA_ARN}/invocations"

# Set up methods and integration
echo "Setting up methods and integration..."
HTTP_METHODS="GET POST PUT PATCH DELETE OPTIONS"

for method in $HTTP_METHODS; do
  # Create method
  if [ "$method" = "OPTIONS" ]; then
    # OPTIONS method for CORS (mock integration)
    aws apigateway put-method \
      --rest-api-id "$API_ID" \
      --resource-id "$PROXY_RESOURCE_ID" \
      --http-method "$method" \
      --authorization-type "NONE" \
      --region "$REGION" > /dev/null 2>&1 || true

    # Create temporary files for OPTIONS integration
    OPT_REQ_TEMPLATE=$(mktemp)
    OPT_METHOD_RES_PARAMS=$(mktemp)
    OPT_INT_RES_PARAMS=$(mktemp)
    OPT_RES_TEMPLATE=$(mktemp)

    # Mock integration request template
    echo '{"application/json":"{\"statusCode\":200}"}' > "$OPT_REQ_TEMPLATE"
    # Method response parameters (declare headers with true)
    cat > "$OPT_METHOD_RES_PARAMS" << 'EOF'
{
  "method.response.header.Access-Control-Allow-Headers": true,
  "method.response.header.Access-Control-Allow-Methods": true,
  "method.response.header.Access-Control-Allow-Origin": true
}
EOF
    # Integration response parameters (actual values with '*')
    cat > "$OPT_INT_RES_PARAMS" << 'EOF'
{
  "method.response.header.Access-Control-Allow-Headers": "'*'",
  "method.response.header.Access-Control-Allow-Methods": "'*'",
  "method.response.header.Access-Control-Allow-Origin": "'*'"
}
EOF
    # Response template
    echo '{"application/json":""}' > "$OPT_RES_TEMPLATE"

    # Mock integration for OPTIONS
    aws apigateway put-integration \
      --rest-api-id "$API_ID" \
      --resource-id "$PROXY_RESOURCE_ID" \
      --http-method "$method" \
      --type MOCK \
      --request-templates "file://$OPT_REQ_TEMPLATE" \
      --region "$REGION" > /dev/null 2>&1 || true

    # Set up method response (declares the headers)
    aws apigateway put-method-response \
      --rest-api-id "$API_ID" \
      --resource-id "$PROXY_RESOURCE_ID" \
      --http-method "$method" \
      --status-code 200 \
      --response-parameters "file://$OPT_METHOD_RES_PARAMS" \
      --region "$REGION" > /dev/null 2>&1 || true

    # Set up integration response (provides the values)
    aws apigateway put-integration-response \
      --rest-api-id "$API_ID" \
      --resource-id "$PROXY_RESOURCE_ID" \
      --http-method "$method" \
      --status-code 200 \
      --response-templates "file://$OPT_RES_TEMPLATE" \
      --response-parameters "file://$OPT_INT_RES_PARAMS" \
      --region "$REGION" > /dev/null 2>&1 || true

    # Cleanup temp files
    rm -f "$OPT_REQ_TEMPLATE" "$OPT_METHOD_RES_PARAMS" "$OPT_INT_RES_PARAMS" "$OPT_RES_TEMPLATE"
  else
    # Regular methods with Lambda proxy integration
    aws apigateway put-method \
      --rest-api-id "$API_ID" \
      --resource-id "$PROXY_RESOURCE_ID" \
      --http-method "$method" \
      --authorization-type "NONE" \
      --region "$REGION" > /dev/null 2>&1 || true

    # AWS_PROXY integration with Lambda
    aws apigateway put-integration \
      --rest-api-id "$API_ID" \
      --resource-id "$PROXY_RESOURCE_ID" \
      --http-method "$method" \
      --type AWS_PROXY \
      --integration-http-method POST \
      --uri "$LAMBDA_URI" \
      --region "$REGION" > /dev/null 2>&1 || true
  fi
done

echo "✅ Methods configured"

# Add Lambda permission for API Gateway
echo "Adding Lambda permissions..."
STATEMENT_ID="apigateway-${API_ID}-${ENV}"
SOURCE_ARN="arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*/*/*"

aws lambda add-permission \
  --function-name "$FUNCTION_NAME" \
  --statement-id "$STATEMENT_ID" \
  --action "lambda:InvokeFunction" \
  --principal "apigateway.amazonaws.com" \
  --source-arn "$SOURCE_ARN" \
  --region "$REGION" 2>/dev/null || echo "Permission already exists or not needed"

echo "✅ Lambda permissions added"

# Deploy to stage
echo "Deploying to stage: $STAGE_NAME"

# Check if deployment already exists for this stage
EXISTING_DEPLOYMENT=$(aws apigateway get-deployment \
  --rest-api-id "$API_ID" \
  --region "$REGION" \
  --query "items[?stageName=='$STAGE_NAME'].id" \
  --output text 2>/dev/null || echo "")

if [ -z "$EXISTING_DEPLOYMENT" ]; then
  aws apigateway create-deployment \
    --rest-api-id "$API_ID" \
    --stage-name "$STAGE_NAME" \
    --region "$REGION" \
    --description "Deployment for ${ENV}" > /dev/null 2>&1 || {
    # If create fails (stage might exist), try updating
    aws apigateway create-deployment \
      --rest-api-id "$API_ID" \
      --region "$REGION" \
      --description "Deployment for ${ENV}" > /dev/null
    aws apigateway create-stage \
      --rest-api-id "$API_ID" \
      --deployment-id "$(aws apigateway get-deployments --rest-api-id "$API_ID" --region "$REGION" --query 'items[-1].id' --output text)" \
      --stage-name "$STAGE_NAME" \
      --region "$REGION" > /dev/null 2>&1 || true
  }
else
  # Create new deployment and update stage
  NEW_DEPLOYMENT_ID=$(aws apigateway create-deployment \
    --rest-api-id "$API_ID" \
    --region "$REGION" \
    --description "Deployment for ${ENV}" \
    --query 'id' --output text)

  aws apigateway update-stage \
    --rest-api-id "$API_ID" \
    --stage-name "$STAGE_NAME" \
    --patch-operations op=replace,path=/deploymentId,value="$NEW_DEPLOYMENT_ID" \
    --region "$REGION" > /dev/null 2>&1 || true
fi

echo "✅ Deployed to stage: $STAGE_NAME"

# Build API URL
API_URL="https://${API_ID}.execute-api.${REGION}.amazonaws.com/${STAGE_NAME}${API_PREFIX}"

echo ""
echo "========================================="
echo "API Gateway Deployment Complete!"
echo "========================================="
echo "API ID: $API_ID"
echo "Stage: $STAGE_NAME"
echo "API URL: $API_URL"
echo "Invoke URL: ${API_URL}/{path}"
echo ""
