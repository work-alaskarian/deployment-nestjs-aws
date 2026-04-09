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
