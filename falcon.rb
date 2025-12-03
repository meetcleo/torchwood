#!/usr/bin/env -S falcon host
# frozen_string_literal: true

require "falcon/environment/rack"

hostname = File.basename(__dir__)

service hostname do
  include Falcon::Environment::Rack

  # By default, Falcon uses Etc.nprocessors to set the count, which is likely incorrect on shared hosts like Heroku.
  # Review the following for guidance about how to find the right value for your app:
  # https://help.heroku.com/88G3XLA6/what-is-an-acceptable-amount-of-dyno-load
  # https://devcenter.heroku.com/articles/deploying-rails-applications-with-the-puma-web-server#workers
  count ENV.fetch("WEB_CONCURRENCY", 1).to_i

  # If using count > 1 you may want to preload your app to reduce memory usage and increase performance:
  preload "preload.rb"

  # The default port should be 3000, but you can change it to match your Heroku configuration.
  port {ENV.fetch("PORT", 3000).to_i}

  endpoint do
    Async::HTTP::Endpoint
      .parse("http://0.0.0.0:#{port}")
  end
end
