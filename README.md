# deployment-nestjs-aws

Standard AWS Lambda deployment template for NestJS services in ZoneVast ecosystem.

## Quick Start

### 1. Copy to Your Project

```bash
cp -r deployment-nestjs-aws/deployment /path/to/your-project/
cp deployment-nestjs-aws/zvs.config.json /path/to/your-project/
```

### 2. Configure zvs.config.json

Edit `zvs.config.json` in your project root:

```json
{
  "service": "your-service-name",
  "lambda": {
    "handler": "dist/lambda.handler",
    "apiPrefix": "/api/v1"
  },
  "environments": {
    "dev": {
      "functionName": "your-service-dev",
      "configFile": "deployment/config/dev.json"
    }
  }
}
```

### 3. Create Lambda Handler

Copy `deployment/example/lambda.example.ts` to `src/lambda.ts`:

```bash
cp deployment-nestjs-aws/deployment/example/lambda.example.ts your-project/src/lambda.ts
```

### 4. Configure Environment

```bash
cp deployment/config/dev.example.json deployment/config/dev.json
# Edit deployment/config/dev.json with your settings
```

### 5. Deploy

```bash
./deployment/build.sh dev
./deployment/deploy.sh dev
```

## Project Structure

```
your-project/
├── src/
│   ├── lambda.ts          # Lambda handler (copy from example/)
│   ├── main.ts
│   └── app.module.ts
├── deployment/
│   ├── build.sh           # Build script
│   ├── deploy.sh          # Deploy script
│   ├── api-gateway.sh     # API Gateway setup
│   ├── schema.json        # Config validation
│   ├── config/
│   │   ├── dev.json       # Dev environment
│   │   └── prod.json      # Prod environment
│   └── example/
│       └── lambda.example.ts
├── zvs.config.json        # Deployment configuration
└── package.json
```

## Template Structure

```
deployment-nestjs-aws/
├── deployment/
│   ├── build.sh
│   ├── deploy.sh
│   ├── build-layer.sh
│   ├── deploy-layer.sh
│   ├── api-gateway.sh
│   ├── schema.json
│   ├── config/
│   │   └── dev.example.json
│   └── example/
│       └── lambda.example.ts
├── zvs.config.json        # Example config
├── README.md
├── CLAUDE.md
└── .gitignore
```

## Configuration Files

| File | Purpose |
|------|---------|
| `zvs.config.json` | Main deployment config (copy to project root) |
| `deployment/config/dev.json` | Dev environment variables |
| `deployment/config/prod.json` | Prod environment variables |
| `deployment/schema.json` | Config validation schema |

## tsconfig Requirements

Ensure your `tsconfig.json` does NOT have `rootDir: "src"`:

```json
{
  "compilerOptions": {
    "outDir": "./dist",
    "baseUrl": "./"
  }
}
```

This creates flat `dist/` structure required for Lambda handler.

## Scripts

Add to your `package.json`:

```json
{
  "scripts": {
    "deploy:dev": "./deployment/build.sh dev && ./deployment/deploy.sh dev",
    "deploy:prod": "./deployment/build.sh prod && ./deployment/deploy.sh prod"
  }
}
```

## Environment Variables

Edit `deployment/config/dev.json`:

```json
{
  "NODE_ENV": "development",
  "API_PREFIX": "api/v1",
  "CORS_ORIGIN": "*",
  "DATABASE_URL": "postgresql://...",
  "JWT_SECRET": "your-secret"
}
```

## Build Output

```
src/
  lambda.ts       ──tsc──→  dist/lambda.js
  app.module.ts   ──tsc──→  dist/app.module.js

Handler: dist/lambda.handler ✅
```

## Deploy Commands

```bash
# Build only
./deployment/build.sh dev

# Deploy (build + upload)
./deployment/deploy.sh dev

# Deploy to prod
./deployment/deploy.sh prod
```

## Testing

```bash
# Test Lambda
aws lambda invoke \
  --function-name your-service-dev \
  --payload '{"body":"{}","httpMethod":"GET","path":"/api/v1/health"}' \
  response.json

# Test via Function URL
curl https://xxx.lambda-url.eu-central-1.on.aws/api/v1/health
```

## Requirements

- Node.js 18+
- AWS CLI configured
- TypeScript 5+
- NestJS 10+
- Prisma (optional)

## Projects Using This Template

- [zv-flex-auth-service](https://github.com/zonevast/zv-flex-auth-service)
- [zv-water-delivery-service](https://github.com/zonevast/zv-water-delivery-service)

## License

MIT
