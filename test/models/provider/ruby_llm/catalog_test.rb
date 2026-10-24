require "test_helper"

# Catalog transport boundary (#16 finding 4). These tests exercise the real
# Faraday/WebMock boundary: the catalog's live model-list request is bounded,
# never retried, and fails closed with safe structured details. They do not
# involve RubyLLM or the provider adapter, so they are independent of the
# RubyLLM gem version.
class Provider::RubyLlm::CatalogTest < ActiveSupport::TestCase
  ACCOUNT_KEYS = {
    openai: "OPENAI_API_KEY",
    opencode_go: "OPENCODE_GO_API_KEY"
  }.freeze

  ACCOUNT_URLS = {
    openai: Provider::RubyLlm::OPENAI_BASE_URL + "/models",
    # Official Go model list (https://opencode.ai/v2/docs/console/go) is under
    # /inference/go/v1/models, not the legacy /zen/go/v1 or the chat base.
    opencode_go: "https://opencode.ai/inference/go/v1/models".freeze
  }.freeze

  def header_value(request, name)
    request.headers.find { |header, _value| header.to_s.casecmp?(name) }&.last
  end

  def catalog
    Provider::RubyLlm::Catalog.new
  end

  def with_account_key(account, key)
    with_env_overrides(ACCOUNT_KEYS.fetch(account) => key) { yield }
  end

  test "sets explicit finite open and read timeouts with no retry options for both accounts" do
    open_timeout = Provider::RubyLlm::Catalog::CATALOG_OPEN_TIMEOUT_SECONDS
    read_timeout = Provider::RubyLlm::Catalog::CATALOG_READ_TIMEOUT_SECONDS

    assert_kind_of Integer, open_timeout
    assert_operator open_timeout, :>, 0
    assert_operator open_timeout, :<=, 120

    assert_kind_of Integer, read_timeout
    assert_operator read_timeout, :>, 0
    assert_operator read_timeout, :<=, 120

    ACCOUNT_KEYS.each_key do |account|
      connection = mock("catalog_connection_#{account}")
      connection.stubs(:get).returns(stub(body: { "data" => [ { "id" => "any-model" } ] }))

      Faraday.expects(:new).with(
        has_entries(
          url: Provider::RubyLlm::Catalog::ACCOUNTS.fetch(account)[:api_base],
          request: { open_timeout: open_timeout, timeout: read_timeout }
        )
      ).returns(connection)

      with_account_key(account, "test-#{account}-key") do
        catalog.available_references(account)
      end
    end
  end

  test "HTTP status failures retain safe structured details and are never retried for both accounts" do
    cases = {
      401 => [ "Faraday::UnauthorizedError", false ],
      408 => [ "Faraday::RequestTimeoutError", true ],
      429 => [ "Faraday::TooManyRequestsError", true ],
      500 => [ "Faraday::ServerError", true ],
      503 => [ "Faraday::ServerError", true ]
    }

    ACCOUNT_KEYS.each_key do |account|
      cases.each do |status, (error_class, retryable)|
        stub_request(:get, ACCOUNT_URLS.fetch(account))
          .to_return(
            status: status,
            headers: { "Content-Type" => "application/json" },
            body: { "error" => { "message" => "SECRET-PROVIDER-BODY" } }.to_json
          )

        error = nil
        with_account_key(account, "test-#{account}-key") do
          error = assert_raises(Provider::RubyLlm::Catalog::Error) { catalog.available_references(account) }
        end

        assert_equal account.to_s, error.details[:provider_reference]
        assert_equal account, error.details[:account]
        assert_equal error_class, error.details[:error_class]
        assert_equal retryable, error.details[:retryable]
        assert_equal status, error.details[:http_status]

        # The provider body and the account credential never surface, and the
        # catalog makes exactly one attempt (no retry middleware).
        refute_match(/SECRET-PROVIDER-BODY/, error.message)
        refute_match(/test-#{account}-key/, error.message)
        assert_requested :get, ACCOUNT_URLS.fetch(account), times: 1

        WebMock.reset!
      end
    end
  end

  test "timeouts and connection failures are retryable with safe details for both accounts" do
    cases = {
      timeout: [
        ->(stub) { stub.to_raise(Faraday::TimeoutError.new("SECRET-TIMEOUT-DETAIL")) },
        "Faraday::TimeoutError"
      ],
      connection: [
        ->(stub) { stub.to_raise(Faraday::ConnectionFailed.new("SECRET-CONNECTION-DETAIL")) },
        "Faraday::ConnectionFailed"
      ]
    }

    ACCOUNT_KEYS.each_key do |account|
      cases.each do |label, (responder, error_class)|
        responder.call(stub_request(:get, ACCOUNT_URLS.fetch(account)))

        error = nil
        with_account_key(account, "test-#{account}-key") do
          error = assert_raises(Provider::RubyLlm::Catalog::Error) { catalog.available_references(account) }
        end

        assert_equal account, error.details[:account], "#{account} #{label}"
        assert_equal error_class, error.details[:error_class], "#{account} #{label}"
        assert_equal true, error.details[:retryable], "#{account} #{label}"
        assert_nil error.details[:http_status], "#{account} #{label}"
        refute_match(/SECRET-TIMEOUT-DETAIL/, error.message)
        refute_match(/SECRET-CONNECTION-DETAIL/, error.message)

        WebMock.reset!
      end
    end
  end

  test "malformed JSON and malformed shape fail closed as non-retryable for both accounts" do
    ACCOUNT_KEYS.each_key do |account|
      stub_request(:get, ACCOUNT_URLS.fetch(account))
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: "{SECRET-NOT-JSON")

      error = nil
      with_account_key(account, "test-#{account}-key") do
        error = assert_raises(Provider::RubyLlm::Catalog::Error) { catalog.available_references(account) }
      end

      assert_equal account, error.details[:account]
      assert_equal "Faraday::ParsingError", error.details[:error_class]
      assert_equal false, error.details[:retryable]
      refute_match(/SECRET-NOT-JSON/, error.message)

      stub_request(:get, ACCOUNT_URLS.fetch(account))
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: { object: "list" }.to_json)

      shape_error = nil
      with_account_key(account, "test-#{account}-key") do
        shape_error = assert_raises(Provider::RubyLlm::Catalog::Error) { catalog.available_references(account) }
      end

      assert_match(/unexpected model catalog response shape for account '#{account}'/i, shape_error.message)
      assert_equal account, shape_error.details[:account]
      assert_equal "Provider::RubyLlm::Catalog::Error", shape_error.details[:error_class]
      assert_equal false, shape_error.details[:retryable]

      WebMock.reset!
    end
  end

  test "uses the official Go model-list URL and Go session/client headers while OpenAI stays isolated" do
    go_request = nil
    openai_request = nil

    stub_request(:get, ACCOUNT_URLS.fetch(:opencode_go)).to_return do |request|
      go_request = request
      {
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { object: "list", data: [ { "id" => "glm-5.3-flash", "object" => "model" } ] }.to_json
      }
    end

    stub_request(:get, ACCOUNT_URLS.fetch(:openai)).to_return do |request|
      openai_request = request
      {
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { object: "list", data: [ { "id" => "gpt-5-nano", "object" => "model" } ] }.to_json
      }
    end

    with_account_key(:openai, "test-openai-key") do
      catalog.available_references(:openai)
    end

    with_account_key(:opencode_go, "test-go-key") do
      references = catalog.available_references(:opencode_go)
      assert_includes references, "opencode_go/glm-5.3-flash"
    end

    assert_requested :get, ACCOUNT_URLS.fetch(:opencode_go), times: 1
    assert_requested :get, ACCOUNT_URLS.fetch(:openai), times: 1
    assert_not_requested :get, "https://opencode.ai/zen/go/v1/models"

    assert_equal "Bearer test-go-key", header_value(go_request, "Authorization")
    assert_equal "Kuria/1.0", header_value(go_request, "User-Agent")
    assert_match(/\Ases_[0-9a-f]{32}\z/, header_value(go_request, "x-opencode-session"))
    assert_nil header_value(go_request, "OpenAI-Organization")
    assert_nil header_value(go_request, "OpenAI-Project")

    assert_equal "Bearer test-openai-key", header_value(openai_request, "Authorization")
    assert_nil header_value(openai_request, "x-opencode-session")
    refute_equal "Kuria/1.0", header_value(openai_request, "User-Agent")
  end

  test "a failed live lookup never falls back to the static manifest" do
    stub_request(:get, ACCOUNT_URLS.fetch(:openai)).to_return(status: 500, body: "boom")

    with_account_key(:openai, "test-openai-key") do
      assert_raises(Provider::RubyLlm::Catalog::Error) { catalog.available_references(:openai) }
    end
  end
end
