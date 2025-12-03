# frozen_string_literal: true

require "async"

# Forwards requests to AWS Secrets Manager API with caching support.
#
# This service handles all Secrets Manager operations by forwarding them to AWS.
# BatchGetSecretValue has custom handling with:
# 1. Checking the in-memory cache for requested secrets
# 2. Fetching uncached secrets from AWS Secrets Manager
# 3. Splitting large requests into concurrent fiber-based batches if needed
# 4. Storing fetched secrets in the cache
#
# All other operations are forwarded directly to AWS without caching.
#
# Uses Async for fiber-based concurrency to integrate properly with Falcon.
#
# @example
#   forwarder = AwsSecretsManagerForwarder.new
#   response = forwarder.forward(
#     target: "secretsmanager.BatchGetSecretValue",
#     body: '{"SecretIdList": ["my-secret"]}'
#   )
#
# @example
#   forwarder = AwsSecretsManagerForwarder.new
#   response = forwarder.forward(
#     target: "secretsmanager.GetSecretValue",
#     body: '{"SecretId": "my-secret"}'
#   )
class AwsSecretsManagerForwarder
  # Maximum number of secrets per BatchGetSecretValue request (AWS limit).
  MAX_BATCH_SIZE = 20

  # @return [Aws::SecretsManager::Client] the AWS SDK client
  attr_reader :client

  # @return [String] the AWS region
  attr_reader :region

  # @return [SecretsCache] the secrets cache
  attr_reader :cache

  # Initializes a new forwarder.
  #
  # @param region [String, nil] AWS region (defaults to AWS_REGION env var or us-east-1)
  # @param credentials [Aws::Credentials, nil] AWS credentials (defaults to SDK chain)
  # @param cache [SecretsCache, nil] cache instance (defaults to singleton)
  def initialize(region: nil, credentials: nil, cache: nil)
    @region = region || ENV.fetch("AWS_REGION", "us-east-1")
    client_options = { region: @region }
    client_options[:credentials] = credentials if credentials
    @client = Aws::SecretsManager::Client.new(client_options)
    @cache = cache || SecretsCache.instance
  end

  # Forwards a request to AWS Secrets Manager.
  #
  # @param target [String] the X-Amz-Target header value (e.g., "secretsmanager.BatchGetSecretValue")
  # @param body [String] the JSON request body
  # @return [ForwardResponse] the response from AWS
  # @raise [Aws::SecretsManager::Errors::ServiceError] on AWS errors
  def forward(target:, body:)
    operation = extract_operation(target)
    parsed_body = JSON.parse(body)

    result = case operation
    when "BatchGetSecretValue"
      handle_batch_get_secret_value(parsed_body)
    when "GetSecretValue"
      handle_get_secret_value(parsed_body)
    else
      forward_to_aws(operation, parsed_body)
    end

    ForwardResponse.new(
      status: 200,
      body: deep_pascalize_keys(result).to_json,
      headers: { "Content-Type" => "application/x-amz-json-1.1" }
    )
  rescue Aws::SecretsManager::Errors::ServiceError => e
    ForwardResponse.new(
      status: error_status_code(e),
      body: { "__type" => e.class.name.split("::").last, "Message" => e.message }.to_json,
      headers: { "Content-Type" => "application/x-amz-json-1.1" }
    )
  rescue JSON::ParserError => e
    ForwardResponse.new(
      status: 400,
      body: { "__type" => "InvalidRequestException", "Message" => "Invalid JSON: #{e.message}" }.to_json,
      headers: { "Content-Type" => "application/x-amz-json-1.1" }
    )
  rescue NoMethodError => e
    ForwardResponse.new(
      status: 400,
      body: { "__type" => "InvalidRequestException", "Message" => e.message }.to_json,
      headers: { "Content-Type" => "application/x-amz-json-1.1" }
    )
  end

  private

  # Extracts the operation name from the X-Amz-Target header.
  #
  # @param target [String] the X-Amz-Target header value
  # @return [String] the operation name
  def extract_operation(target)
    target.split(".").last
  end

  # Maps AWS errors to HTTP status codes.
  #
  # @param error [Aws::SecretsManager::Errors::ServiceError] the AWS error
  # @return [Integer] the HTTP status code
  def error_status_code(error)
    case error
    when Aws::SecretsManager::Errors::ResourceNotFoundException
      404
    when Aws::SecretsManager::Errors::InvalidParameterException,
         Aws::SecretsManager::Errors::InvalidRequestException
      400
    when Aws::SecretsManager::Errors::ResourceExistsException
      409
    when Aws::SecretsManager::Errors::LimitExceededException
      429
    when Aws::SecretsManager::Errors::InternalServiceError
      500
    else
      400
    end
  end

  # Forwards an operation directly to AWS Secrets Manager.
  #
  # Converts the PascalCase operation name to snake_case and calls the
  # corresponding method on the AWS SDK client.
  #
  # @param operation [String] the operation name (e.g., "GetSecretValue")
  # @param params [Hash] the request parameters with string keys
  # @return [Hash] the response from AWS as a hash
  def forward_to_aws(operation, params)
    method_name = operation.gsub(/([a-z])([A-Z])/, '\1_\2').downcase.to_sym
    symbolized_params = deep_underscore_keys(params)

    response = @client.send(method_name, **symbolized_params)
    response.to_h
  end

  # Recursively converts hash keys from PascalCase to snake_case symbols.
  #
  # @param value [Object] the value to convert
  # @return [Object] the converted value
  def deep_underscore_keys(value)
    case value
    when Hash
      value.transform_keys { |k| k.gsub(/([a-z])([A-Z])/, '\1_\2').downcase.to_sym }
           .transform_values { |v| deep_underscore_keys(v) }
    when Array
      value.map { |v| deep_underscore_keys(v) }
    else
      value
    end
  end

  # Recursively converts hash keys from snake_case to PascalCase strings.
  # This is needed because AWS SDK returns snake_case but AWS REST API expects PascalCase.
  #
  # @param value [Object] the value to convert
  # @return [Object] the converted value with PascalCase string keys
  def deep_pascalize_keys(value)
    case value
    when Hash
      value.transform_keys { |k| k.to_s.split("_").map(&:capitalize).join }
           .transform_values { |v| deep_pascalize_keys(v) }
    when Array
      value.map { |v| deep_pascalize_keys(v) }
    else
      value
    end
  end

  # Handles BatchGetSecretValue with caching and batch splitting.
  #
  # @param params [Hash] the request parameters
  # @return [Hash] the combined response with secret_values and errors
  def handle_batch_get_secret_value(params)
    secret_ids = params["SecretIdList"] || []

    # Check cache for requested secrets (always uses AWSCURRENT)
    cache_result = @cache.get_many(secret_ids)
    cached_secrets = cache_result[:cached]
    missing = cache_result[:missing]

    # Extract just the IDs from missing (which is now an array of hashes)
    missing_ids = missing.map { |m| m[:id] }

    # If all secrets are cached, return immediately
    if missing_ids.empty?
      return {
        secret_values: cached_secrets,
        errors: []
      }
    end

    # Fetch missing secrets from AWS (with batch splitting if needed)
    aws_result = fetch_from_aws(missing_ids)

    # Cache the fetched secrets (uses version_stages from each secret's data)
    @cache.set_many(aws_result[:secret_values])

    # Combine cached and fetched secrets
    {
      secret_values: cached_secrets + aws_result[:secret_values],
      errors: aws_result[:errors]
    }
  end

  # Handles GetSecretValue with caching.
  #
  # @param params [Hash] the request parameters
  # @return [Hash] the secret value response
  def handle_get_secret_value(params)
    secret_id = params["SecretId"]
    version_stage = params["VersionStage"] || SecretsCache::DEFAULT_VERSION_STAGE
    version_id = params["VersionId"]

    # Only use cache if no specific VersionId is requested
    if version_id.nil?
      cache_result = @cache.get_many([ { id: secret_id, version_stage: version_stage } ])

      if cache_result[:cached].any?
        return cache_result[:cached].first
      end
    end

    # Fetch from AWS
    response = @client.get_secret_value(
      secret_id: secret_id,
      version_stage: version_stage,
      version_id: version_id
    )
    secret_data = response.to_h

    # Cache the result (only if no specific version_id was requested)
    @cache.set_many([ secret_data ]) if version_id.nil?

    secret_data
  end

  # Fetches secrets from AWS, splitting into parallel batches if needed.
  #
  # @param secret_ids [Array<String>] list of secret IDs to fetch
  # @return [Hash] combined result with :secret_values and :errors
  def fetch_from_aws(secret_ids)
    # Split into batches of MAX_BATCH_SIZE
    batches = secret_ids.each_slice(MAX_BATCH_SIZE).to_a

    if batches.size == 1
      # Single batch, no parallelization needed
      fetch_batch(batches.first)
    else
      # Multiple batches, fetch in parallel
      fetch_batches_parallel(batches)
    end
  end

  # Fetches a single batch of secrets from AWS.
  #
  # @param secret_ids [Array<String>] list of secret IDs (max MAX_BATCH_SIZE)
  # @return [Hash] result with :secret_values and :errors
  def fetch_batch(secret_ids)
    response = @client.batch_get_secret_value(
      secret_id_list: secret_ids,
      filters: nil
    )

    {
      secret_values: response.secret_values.map(&:to_h),
      errors: response.errors.map(&:to_h)
    }
  end

  # Fetches multiple batches concurrently using Async fibers.
  #
  # Uses Async to run batches concurrently within fibers, which integrates
  # properly with Falcon's fiber-based architecture.
  #
  # @param batches [Array<Array<String>>] array of secret ID batches
  # @return [Hash] combined result with :secret_values and :errors
  def fetch_batches_parallel(batches)
    results = Sync do
      batches.map do |batch|
        Async { fetch_batch(batch) }
      end.map(&:wait)
    end

    # Combine all results
    {
      secret_values: results.flat_map { |r| r[:secret_values] },
      errors: results.flat_map { |r| r[:errors] }
    }
  end
end

# Response object for forwarded requests.
#
# @attr_reader status [Integer] the HTTP status code
# @attr_reader body [String] the JSON response body
# @attr_reader headers [Hash<String, String>] the response headers
ForwardResponse = Struct.new(:status, :body, :headers, keyword_init: true)
