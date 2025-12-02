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

  test "get returns nil for uncached secret" do
    assert_nil @cache.get("nonexistent-secret")
  end

  test "set and get a secret" do
    secret_data = { "name" => "my-secret", "secret_string" => "secret-value" }
    @cache.set("my-secret", "AWSCURRENT", secret_data)

    cached = @cache.get("my-secret", "AWSCURRENT")
    assert_equal secret_data, cached
  end

  test "get uses default version stage" do
    secret_data = { "name" => "my-secret", "secret_string" => "secret-value" }
    @cache.set("my-secret", "AWSCURRENT", secret_data)

    cached = @cache.get("my-secret")
    assert_equal secret_data, cached
  end

  test "different version stages are stored separately" do
    current_data = { "name" => "my-secret", "secret_string" => "current-value" }
    previous_data = { "name" => "my-secret", "secret_string" => "previous-value" }

    @cache.set("my-secret", "AWSCURRENT", current_data)
    @cache.set("my-secret", "AWSPREVIOUS", previous_data)

    assert_equal current_data, @cache.get("my-secret", "AWSCURRENT")
    assert_equal previous_data, @cache.get("my-secret", "AWSPREVIOUS")
  end

  test "get_many returns cached and missing secrets" do
    secret1 = { "name" => "secret-1", "secret_string" => "value-1" }
    secret2 = { "name" => "secret-2", "secret_string" => "value-2" }

    @cache.set("secret-1", "AWSCURRENT", secret1)
    @cache.set("secret-2", "AWSCURRENT", secret2)

    result = @cache.get_many(["secret-1", "secret-2", "secret-3"])

    assert_equal 2, result[:cached].size
    assert_includes result[:cached], secret1
    assert_includes result[:cached], secret2
    assert_equal ["secret-3"], result[:missing]
  end

  test "get_many returns all missing when cache is empty" do
    result = @cache.get_many(["secret-1", "secret-2"])

    assert_empty result[:cached]
    assert_equal ["secret-1", "secret-2"], result[:missing]
  end

  test "get_many returns all cached when all exist" do
    secret1 = { "name" => "secret-1", "secret_string" => "value-1" }
    secret2 = { "name" => "secret-2", "secret_string" => "value-2" }

    @cache.set("secret-1", "AWSCURRENT", secret1)
    @cache.set("secret-2", "AWSCURRENT", secret2)

    result = @cache.get_many(["secret-1", "secret-2"])

    assert_equal 2, result[:cached].size
    assert_empty result[:missing]
  end

  test "set_many caches multiple secrets by name" do
    secrets = [
      { "name" => "secret-1", "secret_string" => "value-1" },
      { "name" => "secret-2", "secret_string" => "value-2" }
    ]

    @cache.set_many(secrets)

    assert_equal secrets[0], @cache.get("secret-1")
    assert_equal secrets[1], @cache.get("secret-2")
  end

  test "set_many caches by both name and ARN" do
    secrets = [
      {
        "name" => "secret-1",
        "arn" => "arn:aws:secretsmanager:us-east-1:123:secret:secret-1",
        "secret_string" => "value-1"
      }
    ]

    @cache.set_many(secrets)

    assert_equal secrets[0], @cache.get("secret-1")
    assert_equal secrets[0], @cache.get("arn:aws:secretsmanager:us-east-1:123:secret:secret-1")
  end

  test "set_many handles symbol keys" do
    secrets = [
      { name: "secret-1", secret_string: "value-1" }
    ]

    @cache.set_many(secrets)

    assert_equal secrets[0], @cache.get("secret-1")
  end

  test "clear removes all entries" do
    @cache.set("secret-1", "AWSCURRENT", { "name" => "secret-1" })
    @cache.set("secret-2", "AWSCURRENT", { "name" => "secret-2" })

    assert_equal 2, @cache.size

    @cache.clear

    assert_equal 0, @cache.size
    assert_nil @cache.get("secret-1")
  end

  test "size returns number of cached entries" do
    assert_equal 0, @cache.size

    @cache.set("secret-1", "AWSCURRENT", { "name" => "secret-1" })
    assert_equal 1, @cache.size

    @cache.set("secret-2", "AWSCURRENT", { "name" => "secret-2" })
    assert_equal 2, @cache.size
  end

  test "cache is thread-safe" do
    threads = 10.times.map do |i|
      Thread.new do
        100.times do |j|
          @cache.set("secret-#{i}-#{j}", "AWSCURRENT", { "name" => "secret-#{i}-#{j}" })
          @cache.get("secret-#{i}-#{j}")
        end
      end
    end

    threads.each(&:join)

    # Should have 1000 entries (10 threads * 100 secrets each)
    assert_equal 1000, @cache.size
  end
end
