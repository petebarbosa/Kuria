if ENV["COVERAGE"] == "true"
  require "simplecov"
  SimpleCov.start "rails" do
    enable_coverage :branch
  end
end

require_relative "../config/environment"

ENV["RAILS_ENV"] ||= "test"

# Set Plaid to sandbox mode for tests
ENV["PLAID_ENV"] = "sandbox"
ENV["PLAID_CLIENT_ID"] ||= "test_client_id"
ENV["PLAID_SECRET"] ||= "test_secret"

# Fixes Segfaults on M1 Macs when running tests in parallel (temporary workaround)
ENV["PGGSSENCMODE"] = "disable"

require "rails/test_help"
require "minitest/autorun"
require "mocha/minitest"
require "aasm/minitest"
require "webmock/minitest"

VCR.configure do |config|
  config.cassette_library_dir = "test/vcr_cassettes"
  config.hook_into :webmock
  config.ignore_localhost = true
  config.default_cassette_options = { erb: true }
  config.filter_sensitive_data("<SYNTH_API_KEY>") { ENV["SYNTH_API_KEY"] }
  config.filter_sensitive_data("<STRIPE_SECRET_KEY>") { ENV["STRIPE_SECRET_KEY"] }
  config.filter_sensitive_data("<STRIPE_WEBHOOK_SECRET>") { ENV["STRIPE_WEBHOOK_SECRET"] }
  config.filter_sensitive_data("<PLAID_CLIENT_ID>") { ENV["PLAID_CLIENT_ID"] }
  config.filter_sensitive_data("<PLAID_SECRET>") { ENV["PLAID_SECRET"] }
end

module ActiveSupport
  class TestCase
    # Redis exposes 16 logical databases by default — the CI redis service and a
    # default Redis install both provide 16. One is left free for the base
    # connection, leaving MAX_PARALLEL_WORKERS available for isolation. A custom
    # Redis configured with fewer databases is unsupported for parallel runs.
    REDIS_PARALLEL_DATABASES = 16
    MAX_PARALLEL_WORKERS = REDIS_PARALLEL_DATABASES - 1

    # Run tests in parallel with the requested workers. Every worker needs its own
    # Redis database (see the setup hook below), so the worker count is capped and
    # an explicit PARALLEL_WORKERS above the cap is rejected rather than allowed to
    # alias two workers onto one database. Serial runs ignore PARALLEL_WORKERS.
    unless ENV["DISABLE_PARALLELIZATION"] == "true"
      requested_workers = ENV["PARALLEL_WORKERS"].presence
      requested_count = requested_workers && Integer(requested_workers, exception: false)

      if requested_workers && !requested_count&.between?(1, MAX_PARALLEL_WORKERS)
        raise "PARALLEL_WORKERS must be between 1 and #{MAX_PARALLEL_WORKERS} " \
              "(got #{requested_workers.inspect}): each parallel worker needs its own " \
              "Redis logical database and only #{MAX_PARALLEL_WORKERS} are free alongside " \
              "the base connection. Lower PARALLEL_WORKERS, or run serially with " \
              "DISABLE_PARALLELIZATION=true."
      end

      parallel_workers = requested_count ||
        [ (Concurrent.available_processor_count || Concurrent.processor_count).floor, MAX_PARALLEL_WORKERS ].min

      parallelize(workers: parallel_workers)
    end

    # Give every parallel worker its own Redis logical database so Redis-backed
    # state can never bleed between workers. Fixture records get deterministic
    # ids (ActiveRecord::FixtureSet.identify), so keys such as
    # AssistantRequestLimiter's "assistant_request_limit:<user.id>" are identical
    # in every worker; without isolation the workers race on the same keys — one
    # worker's teardown clears a counter another worker just set, or pre-exhausts
    # it. All Redis clients in the app and tests are created with `Redis.new`
    # after this fork-time hook runs, and redis-rb resolves ENV["REDIS_URL"] at
    # construction, so a single ENV rewrite isolates every client consistently.
    # The base database stays free because the worker count is capped above.
    parallelize_setup do |worker|
      base_url = ENV["REDIS_URL"] || "redis://127.0.0.1:6379"
      uri = URI.parse(base_url)
      base_db = uri.path.to_s.delete_prefix("/").to_i
      uri.path = "/#{(base_db + worker + 1) % REDIS_PARALLEL_DATABASES}"
      ENV["REDIS_URL"] = uri.to_s
    end

    # https://github.com/simplecov-ruby/simplecov/issues/718#issuecomment-538201587
    if ENV["COVERAGE"] == "true"
      parallelize_setup do |worker|
        SimpleCov.command_name "#{SimpleCov.command_name}-#{worker}"
      end

      parallelize_teardown do |worker|
        SimpleCov.result
      end
    end

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
    def sign_in(user)
      post sessions_path, params: { email: user.email, password: user_password_test }
    end

    def with_env_overrides(overrides = {}, &block)
      ClimateControl.modify(**overrides, &block)
    end

    def with_self_hosting
      Rails.configuration.stubs(:app_mode).returns("self_hosted".inquiry)
      yield
    end

    def with_payments_enabled(value)
      original = Rails.application.config.x.features.payments_enabled
      Rails.application.config.x.features.payments_enabled = value
      yield
    ensure
      Rails.application.config.x.features.payments_enabled = original
    end

    def user_password_test
      "maybetestpassword817983172"
    end
  end
end

Dir[Rails.root.join("test", "interfaces", "**", "*.rb")].each { |f| require f }
