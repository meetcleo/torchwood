# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with this codebase.

**Important**: Keep this file up to date when making significant changes to the project structure, adding new endpoints, or modifying architectural decisions.

## Project Overview

Torchwood is a mock AWS Secrets Manager API server built with Rails. It implements the AWS Secrets Manager API contract for local development and testing purposes.

## Tech Stack

- Ruby 3.4.7
- Rails 8.1 (API-only mode)
- Falcon web server (not Puma)
- No database (in-memory storage only)
- Minitest for testing

## Common Commands

```bash
# Start the server
bundle exec falcon serve --bind http://localhost:3050

# Run tests
bin/rails test

# Rails console
bin/rails console
```

## Architecture

### No Database
This application intentionally has no database. ActiveRecord is not installed. All data is stored in-memory and is ephemeral.

### AWS API Contract
The API follows AWS Secrets Manager conventions:
- All operations use `POST /`
- Action is determined by `X-Amz-Target` header (e.g., `secretsmanager.BatchGetSecretValue`)
- Request/response format is `application/x-amz-json-1.1`

### Key Files

- `app/controllers/secrets_manager_controller.rb` - Main API controller
- `config/routes.rb` - Route definitions

## Implemented Operations

| Operation | X-Amz-Target | Status |
|-----------|--------------|--------|
| BatchGetSecretValue | `secretsmanager.BatchGetSecretValue` | Stub (logs request, returns 200) |

## Adding New Operations

1. Add a new action to `SecretsManagerController`
2. Route based on `X-Amz-Target` header or add a new route
3. Update this table when adding new operations
