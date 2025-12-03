# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

class AwsSecretsManagerForwarderTest < ActiveSupport::TestCase
  setup do
    @cache = SecretsCache.instance
    @cache.clear
    @forwarder = AwsSecretsManagerForwarder.new(region: "us-east-1", cache: @cache)
  end

  teardown do
    @cache.clear
  end

  # === Basic forwarding tests ===

  test "forward BatchGetSecretValue returns successful response" do
    mock_response = mock_aws_response(
      secret_values: [ { name: "test-secret", secret_string: "secret-value" } ],
      errors: []
    )

    mock_client = Minitest::Mock.new
    mock_client.expect(:batch_get_secret_value, mock_response, secret_id_list: [ "test-secret" ], filters: nil)

    @forwarder.instance_variable_set(:@client, mock_client)

    response = @forwarder.forward(
      target: "secretsmanager.BatchGetSecretValue",
      body: '{"SecretIdList": ["test-secret"]}'
    )

    assert_equal 200, response.status
    assert_equal "application/x-amz-json-1.1", response.headers["Content-Type"]

    parsed = JSON.parse(response.body)
    assert_equal 1, parsed["SecretValues"].size

    mock_client.verify
  end

  test "forward handles invalid JSON body" do
    response = @forwarder.forward(
      target: "secretsmanager.BatchGetSecretValue",
      body: "not valid json"
    )

    assert_equal 400, response.status
    parsed = JSON.parse(response.body)
    assert_equal "InvalidRequestException", parsed["__type"]
    assert_includes parsed["Message"], "Invalid JSON"
  end

  test "forward returns error response for unsupported operation" do
    response = @forwarder.forward(
      target: "secretsmanager.UnsupportedOperation",
      body: "{}"
    )

    assert_equal 400, response.status
    parsed = JSON.parse(response.body)
    assert_equal "InvalidRequestException", parsed["__type"]
    assert_includes parsed["Message"], "unsupported_operation"
  end

  # === Caching tests ===

  test "returns cached secrets without calling AWS" do
    # Pre-populate cache
    cached_secret = { name: "cached-secret", secret_string: "cached-value" }
    @cache.set_many([ cached_secret ])

    # Create a mock that will fail if called
    mock_client = Minitest::Mock.new
    @forwarder.instance_variable_set(:@client, mock_client)

    response = @forwarder.forward(
      target: "secretsmanager.BatchGetSecretValue",
      body: '{"SecretIdList": ["cached-secret"]}'
    )

    assert_equal 200, response.status
    parsed = JSON.parse(response.body)
    assert_equal 1, parsed["SecretValues"].size
    assert_equal "cached-secret", parsed["SecretValues"][0]["Name"]

    # Mock should not have been called
    mock_client.verify
  end

  test "fetches uncached secrets from AWS and caches them" do
    mock_response = mock_aws_response(
      secret_values: [ { name: "new-secret", secret_string: "new-value" } ],
      errors: []
    )

    mock_client = Minitest::Mock.new
    mock_client.expect(:batch_get_secret_value, mock_response, secret_id_list: [ "new-secret" ], filters: nil)

    @forwarder.instance_variable_set(:@client, mock_client)

    response = @forwarder.forward(
      target: "secretsmanager.BatchGetSecretValue",
      body: '{"SecretIdList": ["new-secret"]}'
    )

    assert_equal 200, response.status

    # Verify secret was cached
    result = @cache.get_many([ "new-secret" ])
    assert_equal 1, result[:cached].size
    assert_equal "new-secret", result[:cached][0][:name]

    mock_client.verify
  end

  test "combines cached and fetched secrets" do
    # Pre-populate cache with one secret
    cached_secret = { name: "cached-secret", secret_string: "cached-value" }
    @cache.set_many([ cached_secret ])

    # Mock AWS to return only the uncached secret
    mock_response = mock_aws_response(
      secret_values: [ { name: "new-secret", secret_string: "new-value" } ],
      errors: []
    )

    mock_client = Minitest::Mock.new
    mock_client.expect(:batch_get_secret_value, mock_response, secret_id_list: [ "new-secret" ], filters: nil)

    @forwarder.instance_variable_set(:@client, mock_client)

    response = @forwarder.forward(
      target: "secretsmanager.BatchGetSecretValue",
      body: '{"SecretIdList": ["cached-secret", "new-secret"]}'
    )

    assert_equal 200, response.status
    parsed = JSON.parse(response.body)
    assert_equal 2, parsed["SecretValues"].size

    mock_client.verify
  end

  # === Batch splitting tests ===

  test "splits large requests into batches" do
    # Request 25 secrets (exceeds MAX_BATCH_SIZE of 20)
    secret_ids = (1..25).map { |i| "secret-#{i}" }

    # First batch: secrets 1-20
    batch1_response = mock_aws_response(
      secret_values: (1..20).map { |i| { name: "secret-#{i}", secret_string: "value-#{i}" } },
      errors: []
    )

    # Second batch: secrets 21-25
    batch2_response = mock_aws_response(
      secret_values: (21..25).map { |i| { name: "secret-#{i}", secret_string: "value-#{i}" } },
      errors: []
    )

    call_count = 0
    mock_client = Object.new
    mock_client.define_singleton_method(:batch_get_secret_value) do |**args|
      call_count += 1
      if args[:secret_id_list].size == 20
        batch1_response
      else
        batch2_response
      end
    end

    @forwarder.instance_variable_set(:@client, mock_client)

    response = @forwarder.forward(
      target: "secretsmanager.BatchGetSecretValue",
      body: { "SecretIdList" => secret_ids }.to_json
    )

    assert_equal 200, response.status
    parsed = JSON.parse(response.body)
    assert_equal 25, parsed["SecretValues"].size
    assert_equal 2, call_count
  end

  test "does not split requests under batch limit" do
    secret_ids = (1..15).map { |i| "secret-#{i}" }

    mock_response = mock_aws_response(
      secret_values: (1..15).map { |i| { name: "secret-#{i}", secret_string: "value-#{i}" } },
      errors: []
    )

    call_count = 0
    mock_client = Object.new
    mock_client.define_singleton_method(:batch_get_secret_value) do |**_args|
      call_count += 1
      mock_response
    end

    @forwarder.instance_variable_set(:@client, mock_client)

    response = @forwarder.forward(
      target: "secretsmanager.BatchGetSecretValue",
      body: { "SecretIdList" => secret_ids }.to_json
    )

    assert_equal 200, response.status
    assert_equal 1, call_count
  end

  test "combines errors from multiple batches" do
    secret_ids = (1..25).map { |i| "secret-#{i}" }

    batch1_response = mock_aws_response(
      secret_values: (1..19).map { |i| { name: "secret-#{i}", secret_string: "value-#{i}" } },
      errors: [ { secret_id: "secret-20", error_code: "ResourceNotFoundException" } ]
    )

    batch2_response = mock_aws_response(
      secret_values: (21..24).map { |i| { name: "secret-#{i}", secret_string: "value-#{i}" } },
      errors: [ { secret_id: "secret-25", error_code: "ResourceNotFoundException" } ]
    )

    mock_client = Object.new
    mock_client.define_singleton_method(:batch_get_secret_value) do |**args|
      if args[:secret_id_list].size == 20
        batch1_response
      else
        batch2_response
      end
    end

    @forwarder.instance_variable_set(:@client, mock_client)

    response = @forwarder.forward(
      target: "secretsmanager.BatchGetSecretValue",
      body: { "SecretIdList" => secret_ids }.to_json
    )

    assert_equal 200, response.status
    parsed = JSON.parse(response.body)
    assert_equal 23, parsed["SecretValues"].size
    assert_equal 2, parsed["Errors"].size
  end

  # === GetSecretValue caching tests ===

  test "GetSecretValue returns cached secret without calling AWS" do
    # Pre-populate cache
    cached_secret = { name: "cached-secret", secret_string: "cached-value", version_stages: [ "AWSCURRENT" ] }
    @cache.set_many([ cached_secret ])

    # Create a mock that will fail if called
    mock_client = Minitest::Mock.new
    @forwarder.instance_variable_set(:@client, mock_client)

    response = @forwarder.forward(
      target: "secretsmanager.GetSecretValue",
      body: '{"SecretId": "cached-secret"}'
    )

    assert_equal 200, response.status
    parsed = JSON.parse(response.body)
    assert_equal "cached-secret", parsed["Name"]
    assert_equal "cached-value", parsed["SecretString"]

    # Mock should not have been called
    mock_client.verify
  end

  test "GetSecretValue fetches from AWS and caches result" do
    mock_response = Object.new
    mock_response.define_singleton_method(:to_h) do
      { name: "new-secret", secret_string: "new-value", version_stages: [ "AWSCURRENT" ] }
    end

    mock_client = Minitest::Mock.new
    mock_client.expect(:get_secret_value, mock_response,
      secret_id: "new-secret", version_stage: "AWSCURRENT", version_id: nil)

    @forwarder.instance_variable_set(:@client, mock_client)

    response = @forwarder.forward(
      target: "secretsmanager.GetSecretValue",
      body: '{"SecretId": "new-secret"}'
    )

    assert_equal 200, response.status

    # Verify secret was cached
    result = @cache.get_many([ "new-secret" ])
    assert_equal 1, result[:cached].size

    mock_client.verify
  end

  test "GetSecretValue respects VersionStage parameter" do
    # Cache AWSCURRENT
    cached_secret = { name: "my-secret", secret_string: "current", version_stages: [ "AWSCURRENT" ] }
    @cache.set_many([ cached_secret ])

    # Request AWSPREVIOUS should miss cache
    mock_response = Object.new
    mock_response.define_singleton_method(:to_h) do
      { name: "my-secret", secret_string: "previous", version_stages: [ "AWSPREVIOUS" ] }
    end

    mock_client = Minitest::Mock.new
    mock_client.expect(:get_secret_value, mock_response,
      secret_id: "my-secret", version_stage: "AWSPREVIOUS", version_id: nil)

    @forwarder.instance_variable_set(:@client, mock_client)

    response = @forwarder.forward(
      target: "secretsmanager.GetSecretValue",
      body: '{"SecretId": "my-secret", "VersionStage": "AWSPREVIOUS"}'
    )

    assert_equal 200, response.status
    mock_client.verify
  end

  test "GetSecretValue bypasses cache when VersionId is specified" do
    # Pre-populate cache
    cached_secret = { name: "my-secret", secret_string: "cached", version_stages: [ "AWSCURRENT" ] }
    @cache.set_many([ cached_secret ])

    # Request with specific VersionId should still call AWS
    mock_response = Object.new
    mock_response.define_singleton_method(:to_h) do
      { name: "my-secret", secret_string: "specific-version", version_id: "abc123" }
    end

    mock_client = Minitest::Mock.new
    mock_client.expect(:get_secret_value, mock_response,
      secret_id: "my-secret", version_stage: "AWSCURRENT", version_id: "abc123")

    @forwarder.instance_variable_set(:@client, mock_client)

    response = @forwarder.forward(
      target: "secretsmanager.GetSecretValue",
      body: '{"SecretId": "my-secret", "VersionId": "abc123"}'
    )

    assert_equal 200, response.status
    mock_client.verify
  end

  # === Error handling tests ===

  test "forward handles ResourceNotFoundException" do
    error = Aws::SecretsManager::Errors::ResourceNotFoundException.new(nil, "Secret not found")

    mock_client = Minitest::Mock.new
    mock_client.expect(:batch_get_secret_value, nil) do |_args|
      raise error
    end

    @forwarder.instance_variable_set(:@client, mock_client)

    response = @forwarder.forward(
      target: "secretsmanager.BatchGetSecretValue",
      body: '{"SecretIdList": ["nonexistent-secret"]}'
    )

    assert_equal 404, response.status
    parsed = JSON.parse(response.body)
    assert_equal "ResourceNotFoundException", parsed["__type"]
  end

  # === Integration tests for version stage caching ===

  test "caches secrets by version stage and fetches missing stages from AWS" do
    # Secret A has stages AWSCURRENT and CLEO-001
    # Secret B has stages AWSCURRENT and CLEO-002
    secret_a = {
      name: "secret-a",
      secret_string: "value-a",
      version_stages: %w[AWSCURRENT CLEO-001]
    }
    secret_b = {
      name: "secret-b",
      secret_string: "value-b",
      version_stages: %w[AWSCURRENT CLEO-002]
    }

    batch_response = mock_aws_response(
      secret_values: [ secret_a, secret_b ],
      errors: []
    )

    aws_calls = []
    mock_client = Object.new
    mock_client.define_singleton_method(:batch_get_secret_value) do |**args|
      aws_calls << { method: :batch_get_secret_value, args: args }
      batch_response
    end
    mock_client.define_singleton_method(:get_secret_value) do |**args|
      aws_calls << { method: :get_secret_value, args: args }
      # Return appropriate secret based on request
      response = Object.new
      response.define_singleton_method(:to_h) do
        {
          name: args[:secret_id],
          secret_string: "#{args[:secret_id]}-#{args[:version_stage]}",
          version_stages: [ args[:version_stage] ]
        }
      end
      response
    end

    @forwarder.instance_variable_set(:@client, mock_client)

    # Step 1: Batch request for secrets A and B
    response1 = @forwarder.forward(
      target: "secretsmanager.BatchGetSecretValue",
      body: '{"SecretIdList": ["secret-a", "secret-b"]}'
    )
    assert_equal 200, response1.status
    parsed1 = JSON.parse(response1.body)
    assert_equal 2, parsed1["SecretValues"].size

    # Verify only one AWS call was made (the batch)
    assert_equal 1, aws_calls.size
    assert_equal :batch_get_secret_value, aws_calls[0][:method]

    # Step 2: Request secret B with stage CLEO-001 (not cached for B)
    response2 = @forwarder.forward(
      target: "secretsmanager.GetSecretValue",
      body: '{"SecretId": "secret-b", "VersionStage": "CLEO-001"}'
    )
    assert_equal 200, response2.status
    parsed2 = JSON.parse(response2.body)
    assert_equal "secret-b", parsed2["Name"]

    # Verify a new AWS call was made
    assert_equal 2, aws_calls.size
    assert_equal :get_secret_value, aws_calls[1][:method]
    assert_equal "secret-b", aws_calls[1][:args][:secret_id]
    assert_equal "CLEO-001", aws_calls[1][:args][:version_stage]

    # Step 3: Request secret A with stage CLEO-002 (not cached for A)
    response3 = @forwarder.forward(
      target: "secretsmanager.GetSecretValue",
      body: '{"SecretId": "secret-a", "VersionStage": "CLEO-002"}'
    )
    assert_equal 200, response3.status
    parsed3 = JSON.parse(response3.body)
    assert_equal "secret-a", parsed3["Name"]

    # Verify another AWS call was made
    assert_equal 3, aws_calls.size
    assert_equal :get_secret_value, aws_calls[2][:method]
    assert_equal "secret-a", aws_calls[2][:args][:secret_id]
    assert_equal "CLEO-002", aws_calls[2][:args][:version_stage]

    # Step 4: Request secret A with stage CLEO-001 (should be cached!)
    response4 = @forwarder.forward(
      target: "secretsmanager.GetSecretValue",
      body: '{"SecretId": "secret-a", "VersionStage": "CLEO-001"}'
    )
    assert_equal 200, response4.status
    parsed4 = JSON.parse(response4.body)
    assert_equal "secret-a", parsed4["Name"]

    # Verify NO new AWS call was made (still 3 calls)
    assert_equal 3, aws_calls.size, "Expected cache hit for secret-a with CLEO-001 stage"

    # Step 5: Request secret B with stage CLEO-002 (should be cached!)
    response5 = @forwarder.forward(
      target: "secretsmanager.GetSecretValue",
      body: '{"SecretId": "secret-b", "VersionStage": "CLEO-002"}'
    )
    assert_equal 200, response5.status
    parsed5 = JSON.parse(response5.body)
    assert_equal "secret-b", parsed5["Name"]

    # Verify NO new AWS call was made (still 3 calls)
    assert_equal 3, aws_calls.size, "Expected cache hit for secret-b with CLEO-002 stage"
  end

  # === Region configuration tests ===

  test "uses default region when not specified" do
    original_region = ENV["AWS_REGION"]
    ENV["AWS_REGION"] = "eu-west-1"
    forwarder = AwsSecretsManagerForwarder.new

    assert_equal "eu-west-1", forwarder.region
  ensure
    if original_region
      ENV["AWS_REGION"] = original_region
    else
      ENV.delete("AWS_REGION")
    end
  end

  test "uses us-east-1 as fallback region" do
    original_region = ENV["AWS_REGION"]
    ENV.delete("AWS_REGION")
    forwarder = AwsSecretsManagerForwarder.new

    assert_equal "us-east-1", forwarder.region
  ensure
    ENV["AWS_REGION"] = original_region if original_region
  end

  private

  # Creates a mock AWS BatchGetSecretValue response.
  #
  # @param secret_values [Array<Hash>] array of secret value hashes
  # @param errors [Array<Hash>] array of error hashes
  # @return [Object] mock response object
  def mock_aws_response(secret_values:, errors:)
    response = Object.new
    response.define_singleton_method(:secret_values) do
      secret_values.map do |sv|
        obj = Object.new
        obj.define_singleton_method(:to_h) { sv }
        obj
      end
    end
    response.define_singleton_method(:errors) do
      errors.map do |err|
        obj = Object.new
        obj.define_singleton_method(:to_h) { err }
        obj
      end
    end
    response
  end
end
