# frozen_string_literal: true

# In-memory cache for AWS Secrets Manager secret values.
#
# Caches secrets by their ID and version stage combination.
# Thread-safe using a Mutex for concurrent access.
#
# @example
#   cache = SecretsCache.instance
#   cache.set("my-secret", "AWSCURRENT", secret_data)
#   cached = cache.get("my-secret", "AWSCURRENT")
class SecretsCache
  include Singleton

  # Default version stage if none specified.
  DEFAULT_VERSION_STAGE = "AWSCURRENT"

  def initialize
    @cache = {}
    @mutex = Mutex.new
  end

  # Retrieves a cached secret value.
  #
  # @param secret_id [String] the secret ID or ARN
  # @param version_stage [String] the version stage (default: AWSCURRENT)
  # @return [Hash, nil] the cached secret data or nil if not found
  def get(secret_id, version_stage = DEFAULT_VERSION_STAGE)
    @mutex.synchronize do
      @cache[cache_key(secret_id, version_stage)]
    end
  end

  # Stores a secret value in the cache.
  #
  # @param secret_id [String] the secret ID or ARN
  # @param version_stage [String] the version stage
  # @param secret_data [Hash] the secret data to cache
  # @return [Hash] the cached secret data
  def set(secret_id, version_stage, secret_data)
    @mutex.synchronize do
      @cache[cache_key(secret_id, version_stage)] = secret_data
    end
  end

  # Retrieves multiple secrets from cache.
  #
  # @param secret_ids [Array<String>] list of secret IDs to retrieve
  # @param version_stage [String] the version stage (default: AWSCURRENT)
  # @return [Hash] hash with :cached (found secrets) and :missing (secret IDs not in cache)
  def get_many(secret_ids, version_stage = DEFAULT_VERSION_STAGE)
    cached = []
    missing = []

    @mutex.synchronize do
      secret_ids.each do |secret_id|
        key = cache_key(secret_id, version_stage)
        if @cache.key?(key)
          cached << @cache[key]
        else
          missing << secret_id
        end
      end
    end

    { cached: cached, missing: missing }
  end

  # Stores multiple secrets in the cache.
  #
  # @param secrets [Array<Hash>] array of secret data hashes (must include :name or "Name")
  # @param version_stage [String] the version stage
  # @return [void]
  def set_many(secrets, version_stage = DEFAULT_VERSION_STAGE)
    @mutex.synchronize do
      secrets.each do |secret_data|
        secret_id = secret_data[:name] || secret_data["name"] ||
                    secret_data[:arn] || secret_data["arn"]
        next unless secret_id

        @cache[cache_key(secret_id, version_stage)] = secret_data
        # Also cache by ARN if we have both name and ARN
        arn = secret_data[:arn] || secret_data["arn"]
        if arn && arn != secret_id
          @cache[cache_key(arn, version_stage)] = secret_data
        end
      end
    end
  end

  # Clears all cached secrets.
  #
  # @return [void]
  def clear
    @mutex.synchronize do
      @cache.clear
    end
  end

  # Returns the number of cached entries.
  #
  # @return [Integer] cache size
  def size
    @mutex.synchronize do
      @cache.size
    end
  end

  private

  # Generates a cache key from secret ID and version stage.
  #
  # @param secret_id [String] the secret ID or ARN
  # @param version_stage [String] the version stage
  # @return [String] the cache key
  def cache_key(secret_id, version_stage)
    "#{secret_id}:#{version_stage}"
  end
end
