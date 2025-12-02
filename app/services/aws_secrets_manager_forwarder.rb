# frozen_string_literal: true

# Forwards requests to AWS Secrets Manager API.
#
# This service takes the raw request details and forwards them to the actual
# AWS Secrets Manager endpoint, signing the request using AWS credentials.
#
# @example
#   forwarder = AwsSecretsManagerForwarder.new
#   response = forwarder.forward(
#     target: "secretsmanager.BatchGetSecretValue",
#     body: '{"SecretIdList": ["my-secret"]}'
#   )
class AwsSecretsManagerForwarder
  # @return [Aws::SecretsManager::Client] the AWS SDK client
  attr_reader :client

  # @return [String] the AWS region
  attr_reader :region

  # Initializes a new forwarder.
  #
  # @param region [String, nil] AWS region (defaults to AWS_REGION env var or us-east-1)
  # @param credentials [Aws::Credentials, nil] AWS credentials (defaults to SDK chain)
  def initialize(region: nil, credentials: nil)
    @region = region || ENV.fetch("AWS_REGION", "us-east-1")
    client_options = { region: @region }
    client_options[:credentials] = credentials if credentials
    @client = Aws::SecretsManager::Client.new(client_options)
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
      forward_batch_get_secret_value(parsed_body)
    else
      raise NotImplementedError, "Operation #{operation} is not supported"
    end

    ForwardResponse.new(
      status: 200,
      body: result.to_h.to_json,
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

  # Forwards a BatchGetSecretValue request.
  #
  # @param params [Hash] the request parameters
  # @return [Aws::SecretsManager::Types::BatchGetSecretValueResponse]
  def forward_batch_get_secret_value(params)
    @client.batch_get_secret_value(
      secret_id_list: params["SecretIdList"],
      filters: params["Filters"]&.map { |f| { key: f["Key"], values: f["Values"] } }
    )
  end
end

# Response object for forwarded requests.
#
# @attr_reader status [Integer] the HTTP status code
# @attr_reader body [String] the JSON response body
# @attr_reader headers [Hash<String, String>] the response headers
ForwardResponse = Struct.new(:status, :body, :headers, keyword_init: true)
