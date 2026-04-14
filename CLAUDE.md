# CLAUDE - NestJS AWS Lambda Deployment Template

Standard deployment pattern for ZoneVast NestJS microservices on AWS Lambda.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                   Local Development                         │
│  ┌────────────┐    ┌──────────┐    ┌────────────┐        │
│  │ src/      │ ──→ │ dist/    │ ──→ │ Lambda ZIP │        │
│  │ *.ts      │ tsc │ *.js     │ zip │ temp/*.zip │        │
│  └────────────┘    └──────────┘    └────────────┘        │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                      AWS Lambda (nodejs18.x)                │
│  Handler: dist/lambda.handler                              │
│  ┌──────────────────────────────────────────────┐         │
│  │ aws-serverless-express (NestJS bridge)       │         │
│  │  ┌─────────────────────────────────────┐    │         │
│  │  │ NestJS App (cached for warm starts) │    │         │
│  │  │  - Controllers                       │    │         │
│  │  │  - Services                         │    │         │
│  │  │  - Guards / Middleware              │    │         │
│  │  └─────────────────────────────────────┘    │         │
│  └──────────────────────────────────────────────┘         │
└─────────────────────────────────────────────────────────────┘
         │
         ├── Function URL (dev default)
         └── API Gateway (prod default)
```

## Critical Pattern: Flat dist Structure

**Why**: Lambda handler path must match actual file location

```
❌ WRONG:                          ✅ CORRECT:
src/                               src/
  lambda.ts    →  dist/src/          lambda.ts    →  dist/
  app.module.ts →  dist/src/          app.module.ts →  dist/
                                     (flat output)

Handler: "dist/src/lambda.handler"  Handler: "dist/lambda.handler"
```

**How**: Remove `rootDir` from tsconfig.json

```json
{
  "compilerOptions": {
    "outDir": "./dist",
    "baseUrl": "./"
    // NO "rootDir": "src"
  }
}
```

## Build Script Flow

```bash
build.sh:
1. rm -rf dist build temp          # Clean
2. npx prisma generate             # Prisma client
3. npx tsc -p tsconfig.build.json  # Compile TypeScript
4. mkdir -p build                  # Create build dir
5. cp -r dist/* build/             # Copy compiled files
6. cp package.json build/          # Copy package files
7. cp -r node_modules/@prisma/*    # Copy Prisma client
8. zip -r temp/service.zip         # Create ZIP
9. rm -rf build dist               # Cleanup
```

## Deploy Script Flow

```bash
deploy.sh:
1. Check if ZIP exists, build if not
2. aws lambda get-function         # Check if exists
3. aws lambda update-function-code # Upload ZIP
4. aws lambda update-function-configuration # Update env vars
5. aws lambda create-function-url-config # Function URL
6. ./api-gateway.sh                # Setup API Gateway
```

## Config File Structure

`zvs.config.json` validates against `schema.json`:

```json
{
  "$schema": "./deployment/schema.json",
  "service": "string",              // Service name (ZIP filename)
  "aws": {
    "region": "eu-central-1",
    "s3Bucket": "optional"          // For large packages >50MB
  },
  "lambda": {
    "runtime": "nodejs18.x",
    "handler": "dist/lambda.handler",
    "memorySize": 512,
    "timeout": 30,
    "layers": [],
    "apiPrefix": "/api/v1"
  },
  "environments": {
    "dev": {
      "functionName": "service-dev",
      "roleArn": "arn:aws:iam::...",
      "configFile": "deployment/config/dev.json",
      "memorySize": 512,            // Optional override
      "timeout": 30,                // Optional override
      "apiGateway": {
        "enabled": false,
        "stageName": "dev"
      }
    }
  }
}
```

## Environment Variables

Loaded from `config/{env}.json`:

```json
{
  "NODE_ENV": "development",
  "API_PREFIX": "api/v1",
  "CORS_ORIGIN": "*",
  "DATABASE_URL": "postgresql://...",
  "JWT_SECRET": "...",
  "REDIS_HOST": "localhost",
  "REDIS_PORT": "6379"
}
```

## Common Issues & Solutions

### Issue: "Cannot find module"

**Cause**: Wrong import path or missing dependency

**Fix**: Check imports use `./app.module` not `./src/app.module`

### Issue: "Handler not found"

**Cause**: Handler path doesn't match dist structure

**Fix**: 
1. Check `dist/` is flat (no `dist/src/`)
2. Update `zvs.config.json` handler to `dist/lambda.handler`

### Issue: "PrismaClient unable to read file"

**Cause**: Prisma client not included in ZIP

**Fix**: Check `build.sh` copies `node_modules/@prisma/client`

### Issue: "Runtime process exited"

**Cause**: Unhandled error or missing env var

**Fix**: Check CloudWatch logs for detailed error

## Testing Checklist

```bash
# 1. Build locally
./deployment/build.sh dev
ls -lh temp/*.zip

# 2. Deploy to dev
./deployment/deploy.sh dev

# 3. Test health endpoint
curl https://xxx.lambda-url.eu-central-1.on.aws/api/v1/health

# 4. Check logs
aws logs filter-log-events \
  --log-group-name /aws/lambda/service-dev \
  --region eu-central-1

# 5. Test cold start
# Wait 5 min, test again
```

## AWS Lambda Deployment

AWS Lambda deployment requires strict package size limits (262MB uncompressed, 50MB zipped for direct upload, 250MB for container). Always use esbuild or similar bundlers to prune dependencies. Never include node_modules directly.

### Package Size Limits

| Limit | Size | Upload Method |
|-------|------|---------------|
| Zipped package | 50MB | Direct upload to Lambda |
| Zipped package | 250MB | S3 upload |
| Uncompressed | 262MB | Lambda maximum |
| Container image | 10GB | ECR |

### Bundling Strategy

```bash
# Use esbuild for efficient bundling
npx esbuild src/lambda.ts \
  --bundle \
  --minify \
  --platform=node \
  --target=node18 \
  --outfile=dist/lambda.js \
  --external:@prisma/client \
  --external:@aws-sdk/*
```

**Why**: esbuild tree-shakes unused code, reducing package size by 60-80% compared to full node_modules.

## Infrastructure Configuration

For Lambda with VPC/RDS: Security groups must allow outbound from Lambda and inbound to RDS. Lambda needs VPC endpoints for S3/CloudWatch or NAT gateway. Always test database connectivity after deployment.

### VPC Configuration

```
┌─────────────────────────────────────────────────┐
│                   VPC                           │
│  ┌─────────────────┐      ┌─────────────────┐  │
│  │     Lambda      │──────│      RDS        │  │
│  │  Security Group │      │  Security Group │  │
│  │  - Outbound     │      │  - Inbound      │  │
│  └─────────────────┘      └─────────────────┘  │
│                                                  │
│  VPC Endpoints (Optional but recommended):       │
│  - com.amazonaws.eu-central-1.s3                │
│  - com.amazonaws.eu-central-1.logs              │
│                                                  │
│  OR                                              │
│                                                  │
│  NAT Gateway (For internet access)              │
└─────────────────────────────────────────────────┘
```

### Security Group Rules

**Lambda Security Group:**
- Outbound: 3306 (to RDS security group)
- Outbound: 443 (to S3/CloudWatch or VPC endpoints)

**RDS Security Group:**
- Inbound: 3306 (from Lambda security group)

### Testing Connectivity

```bash
# After deployment, test DB connection
aws lambda invoke \
  --function-name service-dev \
  --payload '{"body":"{\"query\":\"SELECT 1\"}"}' \
  response.json

# Check CloudWatch logs
aws logs tail /aws/lambda/service-dev --follow
```

## Working With Multiple Projects

When user wants to check/test/deploy specific APIs, clarify which project immediately. Do not switch between projects without explicit confirmation. Use pwd and ls to verify current directory.

### Project Switching Protocol

```bash
# 1. Always verify current directory
pwd
ls -la

# 2. Ask before switching
echo "Current: $(pwd)"
echo "Target: forms/forms-builder-api"
# Confirm with user before cd

# 3. Use absolute paths when uncertain
cd /c/Users/ASK\ 1/Documents/yousef/forms/forms-builder-api

# 4. Verify project context
cat zvs.config.json | grep service
```

### Common Projects

| Project | Path | Lambda Function |
|---------|------|-----------------|
| forms-builder-api | forms/forms-builder-api | forms-builder-dev |
| lost-persons-api | lostperson/LostPersonsWebAPI | lost-persons-dev |

## TypeScript/Prisma Configuration

Prisma with Lambda requires bundling the generated client (node_modules/.prisma/client) as external modules or using esbuild to include it. Enum decorators must be loaded at runtime - verify @EnumType decorators are imported and used correctly.

### Prisma Client Bundling

```javascript
// esbuild.config.js
module.exports = {
  // ... other config
  external: [
    '@prisma/client',
    '@prisma/client/index.js',
  ],
  // Copy Prisma client after build
  copyPrismaClient: true,
};
```

### build.sh Updates

```bash
# After TypeScript compilation
npx prisma generate

# Copy Prisma client to build directory
mkdir -p build/node_modules/.prisma
cp -r node_modules/.prisma/client build/node_modules/.prisma/

# Or use esbuild plugin
node build.js # esbuild script with Prisma plugin
```

### Enum Decorator Handling

```typescript
// ✅ CORRECT - Import and use decorators
import { EnumType } from '@prisma/client/runtime/library';

@EnumType('UserRole', UserRole)
export class UserRoleDto {}

// ❌ WRONG - Missing import
export class UserRoleDto {} // Will fail at runtime
```

### Runtime Verification

```typescript
// src/lambda.ts - Verify Prisma on cold start
import { PrismaClient } from '@prisma/client';

let prisma: PrismaClient;

export const handler = async (event: any) => {
  if (!prisma) {
    prisma = new PrismaClient();
    // Test connection
    await prisma.$connect();
    console.log('✅ Prisma connected');
  }
  // ... rest of handler
};
```

## Debugging Workflow

When user reports an error code (502, 500, 503), verify the actual error source before proposing fixes. 502 often masks 500 from Lambda. Check Lambda logs first.

### Error Code Investigation

```bash
# 1. Check Lambda logs (actual error source)
aws logs filter-log-events \
  --log-group-name /aws/lambda/service-dev \
  --region eu-central-1 \
  --start-time $(date -d '5 minutes ago' +%s)000 \
  --filter-pattern "ERROR"

# 2. Get recent log streams
aws logs describe-log-streams \
  --log-group-name /aws/lambda/service-dev \
  --order-by LastEventTime \
  --descending \
  --max-items 1

# 3. Tail logs in real-time
aws logs tail /aws/lambda/service-dev --follow

# 4. Invoke Lambda locally for testing
sam local invoke ServiceDevFunction -e event.json
```

### Error Code Mapping

| Error | Common Cause | Where to Look |
|-------|-------------|---------------|
| 502 | Lambda timeout/500 error | Lambda logs first |
| 500 | Unhandled exception | Lambda logs, CloudWatch |
| 503 | Throttling/cold start | Concurrent executions |
| 504 | Gateway timeout | Lambda timeout settings |

### Investigation Checklist

```bash
# ✅ First: Check Lambda logs
aws logs tail /aws/lambda/service-dev --follow

# ✅ Second: Test Lambda directly (bypass API Gateway)
aws lambda invoke \
  --function-name service-dev \
  --payload '{"httpMethod":"GET","path":"/api/v1/health"}' \
  response.json && cat response.json

# ✅ Third: Check Lambda configuration
aws lambda get-function-configuration \
  --function-name service-dev

# ✅ Fourth: Review recent changes
git log --oneline -10
git diff HEAD~1 deployment/

# ✅ Fifth: Test locally
sam local start-api
curl http://localhost:3000/api/v1/health
```

## Performance Tips

1. **Cache NestJS app** - Use `cachedServer` for warm starts
2. **Prisma connection pooling** - Set `DATABASE_URL` pool size
3. **Minimize dependencies** - Use layers for shared packages
4. **Increase memory** - More memory = faster CPU
5. **Enable Provisioned Concurrency** - For consistent performance

## AWS Resources Created

| Resource | Naming Pattern |
|----------|---------------|
| Lambda Function | `{service}-{env}` |
| Log Group | `/aws/lambda/{service}-{env}` |
| Function URL | Auto-generated |
| API Gateway | Per-service or shared |
| IAM Role | `zonevast-microservices-{env}-ZappaLambdaExecutionRole` |

## Adding to New Project

```bash
# 1. Copy template
cp -r deployment-nestjs-aws your-project/deployment

# 2. Create lambda handler
# (see README.md for src/lambda.ts template)

# 3. Create zvs.config.json in project root

# 4. Configure environment files
cp deployment/config/dev.example.json deployment/config/dev.json

# 5. Deploy
./deployment/deploy.sh dev
```
