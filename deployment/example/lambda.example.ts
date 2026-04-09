import { Handler, Context } from 'aws-lambda';
import { NestFactory } from '@nestjs/core';
import { ExpressAdapter } from '@nestjs/platform-express';
import { AppModule } from './app.module';
import { Server } from 'http';
import { createServer, proxy } from 'aws-serverless-express';
import { ConfigService } from '@nestjs/config';
import { ValidationPipe } from '@nestjs/common';

let cachedServer: Server;

/**
 * AWS Lambda handler for NestJS application
 * Uses aws-serverless-express to bridge NestJS with Lambda
 *
 * This file should be placed at: src/lambda.ts
 * After build, it becomes: dist/lambda.js
 * Handler path: dist/lambda.handler
 */
export const handler: Handler = async (event: any, context: Context) => {
  // Reuse cached server for warm starts (performance optimization)
  if (!cachedServer) {
    const expressApp = require('express')();
    const app = await NestFactory.create(
      AppModule,
      new ExpressAdapter(expressApp),
    );

    const configService = app.get(ConfigService);

    // Set API prefix from environment variable
    const apiPrefix = configService.get<string>('API_PREFIX', 'api/v1');
    app.setGlobalPrefix(apiPrefix);

    // Enable CORS
    const corsOrigins = configService
      .get<string>('CORS_ORIGIN', '*')
      .split(',');

    app.enableCors({
      origin: corsOrigins.map((origin) => origin.trim()),
      credentials: true,
      methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'],
      allowedHeaders: ['Content-Type', 'Authorization', 'X-Project-ID'],
    });

    // Enable validation
    app.useGlobalPipes(
      new ValidationPipe({
        whitelist: true,
        forbidNonWhitelisted: true,
        transform: true,
      }),
    );

    await app.init();

    // Create server for Lambda
    cachedServer = createServer(expressApp);
  }

  // Proxy request to NestJS
  return proxy(cachedServer, event, context, 'PROMISE').promise;
};
