class SecretsManagerController < ApplicationController
  def batch_get_secret_value
    Rails.logger.info "=== BatchGetSecretValue Request ==="
    Rails.logger.info "Headers:"
    request.headers.each do |key, value|
      Rails.logger.info "  #{key}: #{value}" if key.start_with?("HTTP_", "CONTENT_")
    end
    Rails.logger.info "Body: #{request.raw_post}"
    Rails.logger.info "==================================="

    head :ok
  end
end
