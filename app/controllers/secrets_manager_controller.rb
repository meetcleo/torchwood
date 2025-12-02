# frozen_string_literal: true

# Controller for handling AWS Secrets Manager API requests.
#
# This controller acts as a proxy, forwarding requests to the actual
# AWS Secrets Manager service. It follows the AWS API conventions:
# - All operations use POST /
# - Action is determined by X-Amz-Target header
# - Request/response format is application/x-amz-json-1.1
class SecretsManagerController < ApplicationController
  # Handles all Secrets Manager API operations.
  #
  # Forwards the request to AWS Secrets Manager and returns the response.
  #
  # @return [void]
  def handle
    target = request.headers["X-Amz-Target"]

    if target.blank?
      render json: {
        "__type" => "MissingAuthenticationTokenException",
        "Message" => "Missing X-Amz-Target header"
      }, status: :bad_request
      return
    end

    Rails.logger.info "=== SecretsManager Request ==="
    Rails.logger.info "Target: #{target}"
    Rails.logger.info "Body: #{request.raw_post}"
    Rails.logger.info "=============================="

    response = forwarder.forward(target: target, body: request.raw_post)

    response.headers.each do |key, value|
      self.response.headers[key] = value
    end

    render json: response.body, status: response.status
  end

  private

  # Returns the forwarder service instance.
  #
  # @return [AwsSecretsManagerForwarder] the forwarder service
  def forwarder
    @forwarder ||= AwsSecretsManagerForwarder.new
  end
end
