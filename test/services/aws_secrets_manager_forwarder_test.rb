# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

class AwsSecretsManagerForwarderTest < ActiveSupport::TestCase
  setup do
    @forwarder = AwsSecretsManagerForwarder.new(region: "us-east-1")
  end

  test "forward BatchGetSecretValue returns successful response" do
    mock_response = Minitest::Mock.new
    mock_response.expect(:to_h, { secret_values: [] })

    mock_client = Minitest::Mock.new
    mock_client.expect(:batch_get_secret_value, mock_response, secret_id_list: ["test-secret"], filters: nil)

    @forwarder.instance_variable_set(:@client, mock_client)

    response = @forwarder.forward(
      target: "secretsmanager.BatchGetSecretValue",
      body: '{"SecretIdList": ["test-secret"]}'
    )

    assert_equal 200, response.status
    assert_equal "application/x-amz-json-1.1", response.headers["Content-Type"]
    assert_includes response.body, "secret_values"

    mock_client.verify
    mock_response.verify
  end

  test "forward BatchGetSecretValue with filters" do
    mock_response = Minitest::Mock.new
    mock_response.expect(:to_h, { secret_values: [] })

    mock_client = Minitest::Mock.new
    mock_client.expect(:batch_get_secret_value, mock_response,
      secret_id_list: nil,
      filters: [{ key: "name", values: ["prod/"] }]
    )

    @forwarder.instance_variable_set(:@client, mock_client)

    response = @forwarder.forward(
      target: "secretsmanager.BatchGetSecretValue",
      body: '{"Filters": [{"Key": "name", "Values": ["prod/"]}]}'
    )

    assert_equal 200, response.status
    mock_client.verify
  end

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

  test "forward handles InvalidParameterException" do
    error = Aws::SecretsManager::Errors::InvalidParameterException.new(nil, "Invalid parameter")

    mock_client = Minitest::Mock.new
    mock_client.expect(:batch_get_secret_value, nil) do |_args|
      raise error
    end

    @forwarder.instance_variable_set(:@client, mock_client)

    response = @forwarder.forward(
      target: "secretsmanager.BatchGetSecretValue",
      body: '{"SecretIdList": []}'
    )

    assert_equal 400, response.status
    parsed = JSON.parse(response.body)
    assert_equal "InvalidParameterException", parsed["__type"]
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

  test "forward raises NotImplementedError for unsupported operation" do
    assert_raises NotImplementedError do
      @forwarder.forward(
        target: "secretsmanager.UnsupportedOperation",
        body: "{}"
      )
    end
  end

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
end
