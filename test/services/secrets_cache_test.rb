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
    assert_equal ["secret-1", "secret-2"], result[:missing]
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
    assert_equal ["secret-3"], result[:missing]
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
    current = [{ name: "my-secret", secret_string: "current" }]
    previous = [{ name: "my-secret", secret_string: "previous" }]

    @cache.set_many(current, "AWSCURRENT")
    @cache.set_many(previous, "AWSPREVIOUS")

    current_result = @cache.get_many(["my-secret"], "AWSCURRENT")
    previous_result = @cache.get_many(["my-secret"], "AWSPREVIOUS")

    assert_equal "current", current_result[:cached][0][:secret_string]
    assert_equal "previous", previous_result[:cached][0][:secret_string]
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
    assert_equal ["secret-1", "secret-2"], result[:missing]
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
