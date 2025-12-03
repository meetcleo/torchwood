# frozen_string_literal: true

require "test_helper"

class SecretsCacheTest < ActiveSupport::TestCase
  setup do
    @cache = SecretsCache.instance
    @cache.clear
  end

  teardown do
    @cache.clear
  end

  test "get_many returns empty results for empty input" do
    result = @cache.get_many([])

    assert_empty result[:cached]
    assert_empty result[:missing]
  end

  test "get_many returns all missing when cache is empty" do
    result = @cache.get_many(["secret-1", "secret-2"])

    assert_empty result[:cached]
    assert_equal [
      { id: "secret-1", version_stage: "AWSCURRENT" },
      { id: "secret-2", version_stage: "AWSCURRENT" }
    ], result[:missing]
  end

  test "get_many returns cached and missing secrets" do
    secrets = [
      { name: "secret-1", secret_string: "value-1" },
      { name: "secret-2", secret_string: "value-2" }
    ]
    @cache.set_many(secrets)

    result = @cache.get_many(["secret-1", "secret-2", "secret-3"])

    assert_equal 2, result[:cached].size
    assert_includes result[:cached], secrets[0]
    assert_includes result[:cached], secrets[1]
    assert_equal [ { id: "secret-3", version_stage: "AWSCURRENT" } ], result[:missing]
  end

  test "get_many returns all cached when all exist" do
    secrets = [
      { name: "secret-1", secret_string: "value-1" },
      { name: "secret-2", secret_string: "value-2" }
    ]
    @cache.set_many(secrets)

    result = @cache.get_many(["secret-1", "secret-2"])

    assert_equal 2, result[:cached].size
    assert_empty result[:missing]
  end

  test "get_many uses default version stage" do
    secrets = [{ name: "my-secret", secret_string: "value" }]
    @cache.set_many(secrets)

    result = @cache.get_many(["my-secret"])

    assert_equal 1, result[:cached].size
  end

  test "different version stages are stored separately" do
    # version_stages comes from the secret data (as returned by AWS)
    current = [{ name: "my-secret", secret_string: "current", version_stages: [ "AWSCURRENT" ] }]
    previous = [{ name: "my-secret", secret_string: "previous", version_stages: [ "AWSPREVIOUS" ] }]

    @cache.set_many(current)
    @cache.set_many(previous)

    # Use hash syntax to specify version stage per secret
    current_result = @cache.get_many([ { id: "my-secret", version_stage: "AWSCURRENT" } ])
    previous_result = @cache.get_many([ { id: "my-secret", version_stage: "AWSPREVIOUS" } ])

    assert_equal "current", current_result[:cached][0][:secret_string]
    assert_equal "previous", previous_result[:cached][0][:secret_string]
  end

  test "stores secret under all its version stages" do
    # A secret can have multiple version stages (e.g., during rotation)
    secret = [{ name: "my-secret", secret_string: "value", version_stages: [ "AWSCURRENT", "AWSPENDING" ] }]
    @cache.set_many(secret)

    # Should be retrievable by either stage using hash syntax
    current_result = @cache.get_many([ { id: "my-secret", version_stage: "AWSCURRENT" } ])
    pending_result = @cache.get_many([ { id: "my-secret", version_stage: "AWSPENDING" } ])

    assert_equal 1, current_result[:cached].size
    assert_equal 1, pending_result[:cached].size
    assert_equal "value", current_result[:cached][0][:secret_string]
    assert_equal "value", pending_result[:cached][0][:secret_string]
  end

  test "get_many supports per-secret version stage lookups" do
    # Cache secrets with different version stages
    current = { name: "secret-1", secret_string: "current-value", version_stages: [ "AWSCURRENT" ] }
    previous = { name: "secret-2", secret_string: "previous-value", version_stages: [ "AWSPREVIOUS" ] }
    @cache.set_many([ current, previous ])

    # Request secrets with specific version stages
    result = @cache.get_many([
      { id: "secret-1", version_stage: "AWSCURRENT" },
      { id: "secret-2", version_stage: "AWSPREVIOUS" }
    ])

    assert_equal 2, result[:cached].size
    assert_empty result[:missing]
  end

  test "set_many caches multiple secrets by name" do
    secrets = [
      { name: "secret-1", secret_string: "value-1" },
      { name: "secret-2", secret_string: "value-2" }
    ]

    @cache.set_many(secrets)

    result = @cache.get_many(["secret-1", "secret-2"])
    assert_equal 2, result[:cached].size
  end

  test "set_many skips secrets without name" do
    secrets = [
      { name: "secret-1", secret_string: "value-1" },
      { secret_string: "no-name" }
    ]

    @cache.set_many(secrets)

    result = @cache.get_many(["secret-1"])
    assert_equal 1, result[:cached].size
  end

  test "clear removes all entries" do
    secrets = [
      { name: "secret-1", secret_string: "value-1" },
      { name: "secret-2", secret_string: "value-2" }
    ]
    @cache.set_many(secrets)

    @cache.clear

    result = @cache.get_many(["secret-1", "secret-2"])
    assert_empty result[:cached]
    assert_equal [
      { id: "secret-1", version_stage: "AWSCURRENT" },
      { id: "secret-2", version_stage: "AWSCURRENT" }
    ], result[:missing]
  end

  test "cache is thread-safe" do
    threads = 10.times.map do |i|
      Thread.new do
        100.times do |j|
          secrets = [{ name: "secret-#{i}-#{j}", secret_string: "value" }]
          @cache.set_many(secrets)
          @cache.get_many(["secret-#{i}-#{j}"])
        end
      end
    end

    threads.each(&:join)

    # Verify some entries are retrievable
    result = @cache.get_many(["secret-0-0", "secret-9-99"])
    assert_equal 2, result[:cached].size
  end
end
