# frozen_string_literal: true

# Cache for AWS Secrets Manager secret values using Rails.cache.
#
# Provides batch-only API for caching secrets by ID and version stage.
# Uses Rails.cache.read_multi for efficient bulk reads.
#
# @example
#   result = SecretsCache.get_many(["secret-1", "secret-2"])
#   # => { cached: [...], missing: ["secret-2"] }
#
#   SecretsCache.set_many(secrets_from_aws)
class SecretsCache
  # Default version stage if none specified.
  DEFAULT_VERSION_STAGE = "AWSCURRENT"

  # Cache key namespace to avoid collisions with other cached data.
  NAMESPACE = "secrets"

  class << self
    # Returns the singleton instance for compatibility with existing code.
    #
    # @return [SecretsCache] the singleton instance
    def instance
      @instance ||= new
    end

    # Delegates to instance methods for class-level access.
    delegate :get_many, :set_many, :clear, to: :instance
  end

  # Retrieves multiple secrets from cache using read_multi.
  #
  # @param secret_ids [Array<String>] list of secret IDs to retrieve
  # @param version_stage [String] the version stage (default: AWSCURRENT)
  # @return [Hash] hash with :cached (found secrets) and :missing (secret IDs not in cache)
  def get_many(secret_ids, version_stage = DEFAULT_VERSION_STAGE)
    return { cached: [], missing: [] } if secret_ids.empty?

    # Build cache keys and track mapping back to secret IDs
    keys = secret_ids.map { |id| cache_key(id, version_stage) }
    key_to_id = keys.zip(secret_ids).to_h

    # Bulk read from cache
    results = Rails.cache.read_multi(*keys)

    cached = []
    missing = []

    key_to_id.each do |key, secret_id|
      if results.key?(key)
        cached << results[key]
      else
        missing << secret_id
      end
    end

    { cached: cached, missing: missing }
  end

  # Stores multiple secrets in the cache using write_multi.
  #
  # @param secrets [Array<Hash>] array of secret data hashes (must include :name)
  # @param version_stage [String] the version stage
  # @return [void]
  def set_many(secrets, version_stage = DEFAULT_VERSION_STAGE)
    return if secrets.empty?

    entries = secrets.each_with_object({}) do |secret_data, hash|
      secret_id = secret_data[:name]
      next unless secret_id

      hash[cache_key(secret_id, version_stage)] = secret_data
    end

    Rails.cache.write_multi(entries) unless entries.empty?
  end

  # Clears all cached secrets.
  #
  # @return [void]
  def clear
    Rails.cache.delete_matched(/\A#{Regexp.escape(NAMESPACE)}:/)
  end

  private

  # Generates a cache key from secret ID and version stage.
  #
  # @param secret_id [String] the secret ID or ARN
  # @param version_stage [String] the version stage
  # @return [String] the cache key
  def cache_key(secret_id, version_stage)
    "#{NAMESPACE}:#{secret_id}:#{version_stage}"
  end
end
