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
      secret_values: [{ name: "test-secret", secret_string: "secret-value" }],
      errors: []
    )

    mock_client = Minitest::Mock.new
    mock_client.expect(:batch_get_secret_value, mock_response, secret_id_list: ["test-secret"], filters: nil)

    @forwarder.instance_variable_set(:@client, mock_client)

    response = @forwarder.forward(
      target: "secretsmanager.BatchGetSecretValue",
      body: '{"SecretIdList": ["test-secret"]}'
    )

    assert_equal 200, response.status
    assert_equal "application/x-amz-json-1.1", response.headers["Content-Type"]

    parsed = JSON.parse(response.body)
    assert_equal 1, parsed["secret_values"].size

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
    cached_secret = { "name" => "cached-secret", "secret_string" => "cached-value" }
    @cache.set("cached-secret", "AWSCURRENT", cached_secret)

    # Create a mock that will fail if called
    mock_client = Minitest::Mock.new
    @forwarder.instance_variable_set(:@client, mock_client)

    response = @forwarder.forward(
      target: "secretsmanager.BatchGetSecretValue",
      body: '{"SecretIdList": ["cached-secret"]}'
    )

    assert_equal 200, response.status
    parsed = JSON.parse(response.body)
    assert_equal 1, parsed["secret_values"].size
    assert_equal "cached-secret", parsed["secret_values"][0]["name"]

    # Mock should not have been called
    mock_client.verify
  end

  test "fetches uncached secrets from AWS and caches them" do
    mock_response = mock_aws_response(
      secret_values: [{ name: "new-secret", secret_string: "new-value" }],
      errors: []
    )

    mock_client = Minitest::Mock.new
    mock_client.expect(:batch_get_secret_value, mock_response, secret_id_list: ["new-secret"], filters: nil)

    @forwarder.instance_variable_set(:@client, mock_client)

    response = @forwarder.forward(
      target: "secretsmanager.BatchGetSecretValue",
      body: '{"SecretIdList": ["new-secret"]}'
    )

    assert_equal 200, response.status

    # Verify secret was cached
    cached = @cache.get("new-secret")
    assert_not_nil cached
    assert_equal "new-secret", cached[:name]

    mock_client.verify
  end

  test "combines cached and fetched secrets" do
    # Pre-populate cache with one secret
    cached_secret = { "name" => "cached-secret", "secret_string" => "cached-value" }
    @cache.set("cached-secret", "AWSCURRENT", cached_secret)

    # Mock AWS to return only the uncached secret
    mock_response = mock_aws_response(
      secret_values: [{ name: "new-secret", secret_string: "new-value" }],
      errors: []
    )

    mock_client = Minitest::Mock.new
    mock_client.expect(:batch_get_secret_value, mock_response, secret_id_list: ["new-secret"], filters: nil)

    @forwarder.instance_variable_set(:@client, mock_client)

    response = @forwarder.forward(
      target: "secretsmanager.BatchGetSecretValue",
      body: '{"SecretIdList": ["cached-secret", "new-secret"]}'
    )

    assert_equal 200, response.status
    parsed = JSON.parse(response.body)
    assert_equal 2, parsed["secret_values"].size

    mock_client.verify
  end

  test "respects VersionStage parameter for cache lookup" do
    # Cache secret for AWSCURRENT
    current_secret = { "name" => "my-secret", "secret_string" => "current-value" }
    @cache.set("my-secret", "AWSCURRENT", current_secret)

    # Request with AWSPREVIOUS should miss cache and call AWS
    mock_response = mock_aws_response(
      secret_values: [{ name: "my-secret", secret_string: "previous-value" }],
      errors: []
    )

    mock_client = Minitest::Mock.new
    mock_client.expect(:batch_get_secret_value, mock_response, secret_id_list: ["my-secret"], filters: nil)

    @forwarder.instance_variable_set(:@client, mock_client)

    response = @forwarder.forward(
      target: "secretsmanager.BatchGetSecretValue",
      body: '{"SecretIdList": ["my-secret"], "VersionStage": "AWSPREVIOUS"}'
    )

    assert_equal 200, response.status
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
    assert_equal 25, parsed["secret_values"].size
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
      errors: [{ secret_id: "secret-20", error_code: "ResourceNotFoundException" }]
    )

    batch2_response = mock_aws_response(
      secret_values: (21..24).map { |i| { name: "secret-#{i}", secret_string: "value-#{i}" } },
      errors: [{ secret_id: "secret-25", error_code: "ResourceNotFoundException" }]
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
    assert_equal 23, parsed["secret_values"].size
    assert_equal 2, parsed["errors"].size
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
