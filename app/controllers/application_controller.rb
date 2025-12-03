# frozen_string_literal: true

# Base controller for all API controllers.
class ApplicationController < ActionController::API
  # Appends custom data to the instrumentation payload for structured logging.
  #
  # @param payload [Hash] the payload hash to append to
  # @return [void]
  def append_info_to_payload(payload)
    super
    payload[:x_amz_target] = request.headers["X-Amz-Target"]
  end
end
