# frozen_string_literal: true

# Persistent storage for objects that need to survive code reloading.
# In development with single-threaded Falcon, these persist across requests.
module PersistentInstances
  class << self
    def secrets_manager_forwarder
      @secrets_manager_forwarder ||= AwsSecretsManagerForwarder.new
    end

    def clear!
      @secrets_manager_forwarder = nil
    end
  end
end
