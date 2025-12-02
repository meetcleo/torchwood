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
- `app/services/aws_secrets_manager_forwarder.rb` - Forwards requests to AWS Secrets Manager
- `config/routes.rb` - Route definitions

## Implemented Operations

| Operation | X-Amz-Target | Status |
|-----------|--------------|--------|
| BatchGetSecretValue | `secretsmanager.BatchGetSecretValue` | Forwards to AWS |

## Adding New Operations

1. Add a new case to `AwsSecretsManagerForwarder#forward` method
2. Implement the corresponding `forward_*` private method
3. Update this table when adding new operations

## Code Style

### Documentation and Types

When writing Ruby code, always include:

1. **YARD documentation** for all classes, modules, and public methods:
   ```ruby
   # Short description of what the method does.
   #
   # @param name [String] description of parameter
   # @param options [Hash] description of options
   # @return [Boolean] description of return value
   # @raise [ArgumentError] when the input is invalid
   def example_method(name, options = {})
   end
   ```

2. **RBS type signatures** in corresponding `.rbs` files under `sig/`:
   ```rbs
   # sig/app/services/example_service.rbs
   class ExampleService
     def example_method: (String name, ?Hash[Symbol, untyped] options) -> bool
   end
   ```

