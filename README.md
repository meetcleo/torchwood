# Torchwood

A lightweight Rails API that implements the AWS Secrets Manager API contract. Designed for local development and testing scenarios where you need a secrets manager endpoint without connecting to AWS.

## Requirements

- Ruby 3.4.7

## Setup

```bash
bundle install
```

## Running the Server

```bash
bundle exec falcon serve --bind http://localhost:3050
```

## API Endpoints

### BatchGetSecretValue

Implements the AWS Secrets Manager `BatchGetSecretValue` operation.

```bash
curl -X POST http://localhost:3050/ \
  -H "Content-Type: application/x-amz-json-1.1" \
  -H "X-Amz-Target: secretsmanager.BatchGetSecretValue" \
  -d '{"SecretIdList": ["my-secret-1", "my-secret-2"]}'
```

### Health Check

```bash
curl http://localhost:3050/up
```

## Running Tests

```bash
bin/rails test
```

## Architecture

- **Framework**: Rails 8.1 (API-only mode)
- **Web Server**: Falcon
- **Database**: None (in-memory only)
