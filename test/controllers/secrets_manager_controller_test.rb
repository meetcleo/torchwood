# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

class SecretsManagerControllerTest < ActionDispatch::IntegrationTest
  test "returns error when X-Amz-Target header is missing" do
    post "/",
      params: '{"SecretIdList": ["test"]}',
      headers: { "Content-Type" => "application/x-amz-json-1.1" }

    assert_response :bad_request
    parsed = JSON.parse(response.body)
    assert_equal "MissingAuthenticationTokenException", parsed["__type"]
    assert_includes parsed["Message"], "X-Amz-Target"
  end

  test "forwards BatchGetSecretValue request to AWS" do
    mock_forwarder = Minitest::Mock.new
    mock_forwarder.expect(:forward, ForwardResponse.new(
      status: 200,
      body: '{"SecretValues": []}',
      headers: { "Content-Type" => "application/x-amz-json-1.1" }
    ), target: "secretsmanager.BatchGetSecretValue", body: '{"SecretIdList": ["test-secret"]}')

    AwsSecretsManagerForwarder.stub(:new, mock_forwarder) do
      post "/",
        params: '{"SecretIdList": ["test-secret"]}',
        headers: {
          "Content-Type" => "application/x-amz-json-1.1",
          "X-Amz-Target" => "secretsmanager.BatchGetSecretValue"
        }

      assert_response :success
      assert_equal "application/x-amz-json-1.1", response.headers["Content-Type"]
    end

    mock_forwarder.verify
  end

  test "returns 404 for ResourceNotFoundException" do
    mock_forwarder = Minitest::Mock.new
    mock_forwarder.expect(:forward, ForwardResponse.new(
      status: 404,
      body: '{"__type": "ResourceNotFoundException", "Message": "Secret not found"}',
      headers: { "Content-Type" => "application/x-amz-json-1.1" }
    ), target: "secretsmanager.BatchGetSecretValue", body: '{"SecretIdList": ["nonexistent"]}')

    AwsSecretsManagerForwarder.stub(:new, mock_forwarder) do
      post "/",
        params: '{"SecretIdList": ["nonexistent"]}',
        headers: {
          "Content-Type" => "application/x-amz-json-1.1",
          "X-Amz-Target" => "secretsmanager.BatchGetSecretValue"
        }

      assert_response :not_found
      parsed = JSON.parse(response.body)
      assert_equal "ResourceNotFoundException", parsed["__type"]
    end

    mock_forwarder.verify
  end

  test "returns 400 for invalid request" do
    mock_forwarder = Minitest::Mock.new
    mock_forwarder.expect(:forward, ForwardResponse.new(
      status: 400,
      body: '{"__type": "InvalidRequestException", "Message": "Invalid request"}',
      headers: { "Content-Type" => "application/x-amz-json-1.1" }
    ), target: "secretsmanager.BatchGetSecretValue", body: '{"invalid": "params"}')

    AwsSecretsManagerForwarder.stub(:new, mock_forwarder) do
      post "/",
        params: '{"invalid": "params"}',
        headers: {
          "Content-Type" => "application/x-amz-json-1.1",
          "X-Amz-Target" => "secretsmanager.BatchGetSecretValue"
        }

      assert_response :bad_request
    end

    mock_forwarder.verify
  end

  test "sets correct Content-Type header in response" do
    mock_forwarder = Minitest::Mock.new
    mock_forwarder.expect(:forward, ForwardResponse.new(
      status: 200,
      body: '{"SecretValues": []}',
      headers: { "Content-Type" => "application/x-amz-json-1.1" }
    ), target: "secretsmanager.BatchGetSecretValue", body: '{}')

    AwsSecretsManagerForwarder.stub(:new, mock_forwarder) do
      post "/",
        params: "{}",
        headers: {
          "Content-Type" => "application/x-amz-json-1.1",
          "X-Amz-Target" => "secretsmanager.BatchGetSecretValue"
        }

      assert_response :success
      assert_equal "application/x-amz-json-1.1", response.headers["Content-Type"]
    end
  end
end
