# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with this codebase.

**Important**: Keep this file up to date when making significant changes to the project structure, adding new endpoints, or modifying architectural decisions.

## Project Overview

Torchwood is a mock AWS Secrets Manager API server built with Rails. It implements the AWS Secrets Manager API contract for local development and testing purposes.

## Tech Stack

- Ruby 3.4.7
- Rails 8.1 (API-only mode)
- Falcon web server (fiber-based, not Puma)
- No database (in-memory storage only)
- Minitest for testing

### Fiber-Based Concurrency

**Important**: This application uses Falcon, which is fiber-based (not thread-based like Puma). When writing concurrent code:

- **DO** use `Async` / `Sync` from the `async` gem for concurrent operations
- **DO NOT** use `Thread.new` for parallelism - it doesn't integrate well with Falcon's fiber scheduler
- Fibers are cooperative, so CPU-bound work will block other fibers
- I/O operations (HTTP requests, etc.) yield automatically when using async-compatible libraries

```ruby
# Good - fiber-based concurrency
require "async"

Sync do
  tasks = items.map { |item| Async { fetch(item) } }
  results = tasks.map(&:wait)
end

# Bad - thread-based (avoid)
threads = items.map { |item| Thread.new { fetch(item) } }
results = threads.map(&:value)
```

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
- `app/services/aws_secrets_manager_forwarder.rb` - Forwards requests to AWS Secrets Manager (with caching)
- `app/services/secrets_cache.rb` - Thread-safe in-memory cache for secrets
- `config/routes.rb` - Route definitions

### Caching Strategy

The forwarder implements an in-memory caching layer:
- Secrets are cached by ID/ARN and version stage (default: AWSCURRENT)
- Cache is checked before making AWS requests
- Fetched secrets are automatically cached
- Large requests (>20 secrets) are split into concurrent fiber-based batches per AWS limits
- Cache writes are synchronized with a Mutex; reads are lock-free for performance

## Implemented Operations

All AWS Secrets Manager operations are supported and forwarded to AWS:

| Operation | X-Amz-Target | Notes |
|-----------|--------------|-------|
| BatchGetSecretValue | `secretsmanager.BatchGetSecretValue` | Custom handling with caching and batch splitting |
| All other operations | `secretsmanager.<OperationName>` | Direct forwarding to AWS |

Supported operations include: `GetSecretValue`, `CreateSecret`, `DeleteSecret`, `DescribeSecret`, `ListSecrets`, `PutSecretValue`, `UpdateSecret`, `RotateSecret`, `GetRandomPassword`, `TagResource`, `UntagResource`, and more.

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

