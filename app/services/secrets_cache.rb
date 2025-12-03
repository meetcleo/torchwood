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
  # Supports two calling conventions:
  # 1. Array of secret IDs (uses AWSCURRENT):
  #    get_many(["secret-1", "secret-2"])
  # 2. Array of hashes with per-secret version stages:
  #    get_many([{ id: "secret-1", version_stage: "AWSCURRENT" },
  #              { id: "secret-2", version_stage: "AWSPREVIOUS" }])
  #
  # @param secret_ids [Array<String>, Array<Hash>] list of secret IDs or hashes with :id and :version_stage
  # @return [Hash] hash with :cached (found secrets) and :missing (secret ID/stage pairs not in cache)
  def get_many(secret_ids)
    return { cached: [], missing: [] } if secret_ids.empty?

    # Normalize input to array of { id:, version_stage: } hashes
    lookups = normalize_lookups(secret_ids)

    # Build cache keys and track mapping back to lookups
    keys = lookups.map { |l| cache_key(l[:id], l[:version_stage]) }
    key_to_lookup = keys.zip(lookups).to_h

    # Bulk read from cache
    results = Rails.cache.read_multi(*keys)

    cached = []
    missing = []

    key_to_lookup.each do |key, lookup|
      if results.key?(key)
        cached << results[key]
      else
        missing << lookup
      end
    end

    { cached: cached, missing: missing }
  end

  # Stores multiple secrets in the cache using write_multi.
  #
  # Creates cache entries for each version stage associated with the secret.
  # The version stages are read from the :version_stages key in each secret's data.
  # If no version stages are present, falls back to DEFAULT_VERSION_STAGE.
  #
  # @param secrets [Array<Hash>] array of secret data hashes (must include :name,
  #   optionally :version_stages)
  # @return [void]
  def set_many(secrets)
    return if secrets.empty?

    entries = secrets.each_with_object({}) do |secret_data, hash|
      secret_id = secret_data[:name]
      next unless secret_id

      # Use version_stages from the secret data, or fall back to default
      stages = secret_data[:version_stages]
      stages = [ DEFAULT_VERSION_STAGE ] if stages.nil? || stages.empty?

      # Create a cache entry for each version stage
      stages.each do |stage|
        hash[cache_key(secret_id, stage)] = secret_data
      end
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

  # Normalizes lookup input to array of hashes.
  #
  # @param secret_ids [Array<String>, Array<Hash>] the input
  # @return [Array<Hash>] array of { id:, version_stage: } hashes
  def normalize_lookups(secret_ids)
    secret_ids.map do |entry|
      if entry.is_a?(Hash)
        { id: entry[:id], version_stage: entry[:version_stage] || DEFAULT_VERSION_STAGE }
      else
        { id: entry, version_stage: DEFAULT_VERSION_STAGE }
      end
    end
  end

  # Generates a cache key from secret ID and version stage.
  #
  # @param secret_id [String] the secret ID or ARN
  # @param version_stage [String] the version stage
  # @return [String] the cache key
  def cache_key(secret_id, version_stage)
    "#{NAMESPACE}:#{secret_id}:#{version_stage}"
  end
end
