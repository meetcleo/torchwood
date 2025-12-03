# frozen_string_literal: true

# Configures rails_semantic_logger for structured JSON logging.
#
# SemanticLogger provides structured logging with automatic JSON formatting,
# contextual information, and better performance than standard Rails logging.

SemanticLogger.default_level = Rails.env.production? ? :info : :debug

# Use JSON formatter for all environments except test
unless Rails.env.test?
  SemanticLogger.add_appender(
    io: $stdout,
    formatter: :json
  )
end
