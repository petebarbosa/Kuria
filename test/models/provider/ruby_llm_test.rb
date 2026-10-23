require "test_helper"

class Provider::RubyLlmTest < ActiveSupport::TestCase
  include ProviderTestHelper

  # Deterministic stand-ins for the RubyLLM gem boundary. The adapter must
  # never leak RubyLLM objects, so these fakes only exercise the seam the
  # adapter is allowed to touch (RubyLLM.context / context.chat / chat.ask).
  class FakeConfig
    attr_reader :openai_api_key, :openai_api_base, :openai_organization_id, :openai_project_id,
      :request_timeout, :max_retries, :retry_interval, :retry_max_interval,
      :retry_backoff_factor, :retry_interval_randomness, :faraday_adapter

    def openai_api_key=(value)
      @openai_api_key = value
    end

    def openai_api_base=(value)
      @openai_api_base = value
    end

    def openai_organization_id=(value)
      @openai_organization_id = value
    end

    def openai_project_id=(value)
      @openai_project_id = value
    end

    def request_timeout=(value)
      @request_timeout = value
    end

    def max_retries=(value)
      @max_retries = value
    end

    def retry_interval=(value)
      @retry_interval = value
    end

    def retry_max_interval=(value)
      @retry_max_interval = value
    end

    def retry_backoff_factor=(value)
      @retry_backoff_factor = value
    end

    def retry_interval_randomness=(value)
      @retry_interval_randomness = value
    end

    def faraday_adapter=(value)
      @faraday_adapter = value
    end
  end

  class FakeContext
    attr_reader :chat_options

    def initialize(chat)
      @chat = chat
    end

    def chat(**options)
      @chat_options = options
      @chat
    end
  end

  class FakeChat
    attr_reader :prompt, :instructions, :schema

    def initialize(final_message:, chunks: [])
      @final_message = final_message
      @chunks = chunks
    end

    def with_instructions(instructions)
      @instructions = instructions
      self
    end

    def with_schema(schema)
      @schema = schema
      self
    end

    def ask(prompt, &block)
      @prompt = prompt
      @chunks.each { |chunk| block.call(chunk) }
      @final_message
    end
  end

  class FakeMessage
    attr_reader :content

    def initialize(content:, id: nil)
      @content = content
      @id = id
    end

    def id
      @id
    end
  end

  class FakeChunk
    attr_reader :content

    def initialize(content:)
      @content = content
    end
  end

  OPENAI_MODELS_URL = Provider::RubyLlm::OPENAI_BASE_URL + "/models"
  OPENCODE_GO_MODELS_URL = Provider::RubyLlm::OPENCODE_GO_BASE_URL + "/models"
  OPENAI_CHAT_URL = Provider::RubyLlm::OPENAI_BASE_URL + "/chat/completions"
  OPENCODE_GO_CHAT_URL = Provider::RubyLlm::OPENCODE_GO_BASE_URL + "/chat/completions"

  setup do
    @provider = Provider::RubyLlm.new
  end

  def stub_ruby_llm_context(chat, config: FakeConfig.new)
    context = FakeContext.new(chat)
    RubyLLM.stubs(:context).yields(config).returns(context)
    [ config, context ]
  end

  # Live catalog boundary: stub the authenticated `GET /v1/models` request for
  # an account. Header expectations double as assertions that the correct
  # account credential is sent.
  def stub_live_models(account, entries:, auth_key:)
    url = account == :openai ? OPENAI_MODELS_URL : OPENCODE_GO_MODELS_URL

    stub_request(:get, url)
      .with(headers: { "Accept" => "application/json", "Authorization" => "Bearer #{auth_key}" })
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { object: "list", data: entries }.to_json
      )
  end

  def model_entry(id, shutdown_date: nil)
    entry = { "id" => id, "object" => "model" }
    entry["shutdown_date"] = shutdown_date if shutdown_date
    entry
  end

  # Server-sent event helpers for the streaming boundary. Bytes are sent
  # unchanged by the adapter, so these mirror the provider format exactly.
  def sse_event(payload)
    "data: #{payload.is_a?(String) ? payload : payload.to_json}\n\n"
  end

  def sse_comment(text)
    ": #{text}\n\n"
  end

  def sse_error_event(payload)
    "event: error\ndata: #{payload.to_json}\n\n"
  end

  def stream_chunk(content: nil, finish_reason: nil, role: nil, tool_calls: nil)
    delta = {}
    delta["role"] = role if role
    delta["content"] = content unless content.nil?
    delta["tool_calls"] = tool_calls if tool_calls

    {
      "id" => "chatcmpl-stream",
      "object" => "chat.completion.chunk",
      "created" => 1,
      "model" => "gpt-5-nano",
      "choices" => [ { "index" => 0, "delta" => delta, "finish_reason" => finish_reason } ]
    }
  end

  def usage_chunk
    {
      "id" => "chatcmpl-stream",
      "object" => "chat.completion.chunk",
      "model" => "gpt-5-nano",
      "choices" => [],
      "usage" => { "prompt_tokens" => 3, "completion_tokens" => 2, "total_tokens" => 5 }
    }
  end

  def stub_stream(url, body, token:)
    stub_request(:post, url)
      .with(headers: { "Authorization" => "Bearer #{token}" })
      .to_return(status: 200, headers: { "Content-Type" => "text/event-stream" }, body: body)
  end

  # A Faraday env for exercising the streaming adapter directly, including
  # chunk boundaries WebMock cannot produce (it yields the whole body once).
  def stream_env(received)
    env = Faraday::Env.from(
      method: :post,
      url: URI("https://api.openai.com/v1/chat/completions"),
      request: Faraday::RequestOptions.new,
      request_headers: Faraday::Utils::Headers.new,
      response_headers: Faraday::Utils::Headers.new("content-type" => "text/event-stream"),
      status: 200
    )
    env.request.on_data = ->(chunk, _bytes, _callback_env) { received << chunk }
    env
  end

  # Stub the encrypted-credentials boundary (never write real secrets) as a
  # plain lookup keyed by the account credential identifier. ENV precedence is
  # exercised separately via with_env_overrides.
  def with_credentials(mapping)
    Rails.application.stubs(:credentials).returns(mapping)
    yield
  ensure
    Rails.application.unstub(:credentials)
  end

  test "supports only catalog-admitted openai and opencode_go references" do
    assert @provider.supports_model?("openai/gpt-5-nano")
    assert @provider.supports_model?("openai/gpt-4o")
    assert @provider.supports_model?("opencode_go/glm-5.3-flash")
    refute @provider.supports_model?("opencode_go/grok-4-fast")
    refute @provider.supports_model?("opencode/big-pickle")
    refute @provider.supports_model?("anthropic/claude-3-5-sonnet")
    refute @provider.supports_model?("gpt-5-nano")
    refute @provider.supports_model?("openai/")
    refute @provider.supports_model?("openai/gpt-5-nano/extra")
    refute @provider.supports_model?("https://api.openai.com/v1")
    refute @provider.supports_model?("openai/does-not-exist")
    refute @provider.supports_model?("openai/glm-5.3-flash")
    refute @provider.supports_model?("opencode_go/gpt-5-nano")
    refute @provider.supports_model?(nil)
  end

  test "exposes the immutable positive catalog for admin selection" do
    references = @provider.supported_references

    assert_includes references, "openai/gpt-5-nano"
    assert_includes references, "openai/gpt-4o"
    assert_includes references, "opencode_go/glm-5.3-flash"
    assert_includes references, "opencode_go/kimi-k3"
    refute_includes references, "opencode_go/grok-4-fast"
    refute_includes references, "opencode/big-pickle"
    assert references.all? { |reference| reference.match?(%r{\A(openai|opencode_go)/[^/]+\z}) }

    assert_equal Provider::RubyLlm::Catalog.manifest, Provider::RubyLlm.supported_models

    # The catalog is immutable: neither the manifest nor its entries can be
    # mutated after load.
    assert_raises(FrozenError) { Provider::RubyLlm.supported_models["openai/gpt-5-nano"] = {} }
    assert_raises(FrozenError) { Provider::RubyLlm.supported_models["openai/gpt-5-nano"][:billing_account] = "other" }
    assert_raises(FrozenError) { Provider::RubyLlm::Catalog::ACCOUNTS[:openai][:manifest] << "backdoor-model" }
  end

  test "declares resolution metadata distinguishing account, model id, provider, protocol, api base, credential source, billing account, and admission" do
    openai = Provider::RubyLlm.supported_models.fetch("openai/gpt-5-nano")
    assert_equal :openai, openai[:account]
    assert_equal "gpt-5-nano", openai[:model_id]
    assert_equal :openai, openai[:provider]
    assert_equal :chat_completions, openai[:protocol]
    assert_equal Provider::RubyLlm::OPENAI_BASE_URL, openai[:api_base]
    assert_equal "OPENAI_API_KEY", openai[:credential_source]
    assert_equal "openai", openai[:billing_account]
    assert_equal true, openai[:assume_model_exists]

    opencode_go = Provider::RubyLlm.supported_models.fetch("opencode_go/glm-5.3-flash")
    assert_equal :opencode_go, opencode_go[:account]
    assert_equal "glm-5.3-flash", opencode_go[:model_id]
    assert_equal :openai, opencode_go[:provider]
    assert_equal :chat_completions, opencode_go[:protocol]
    assert_equal Provider::RubyLlm::OPENCODE_GO_BASE_URL, opencode_go[:api_base]
    assert_equal "OPENCODE_GO_API_KEY", opencode_go[:credential_source]
    assert_equal "opencode_go", opencode_go[:billing_account]
    assert_equal true, opencode_go[:assume_model_exists]

    # Billing identity, API-base identity, and credential source differ.
    refute_equal openai[:billing_account], opencode_go[:billing_account]
    refute_equal openai[:api_base], opencode_go[:api_base]
    refute_equal openai[:credential_source], opencode_go[:credential_source]
  end

  test "credential_configured? reflects the presence of the required credential" do
    with_env_overrides OPENAI_API_KEY: "k", OPENCODE_GO_API_KEY: nil do
      assert @provider.credential_configured?("openai/gpt-5-nano")
      refute @provider.credential_configured?("opencode_go/glm-5.3-flash")
    end

    with_env_overrides OPENAI_API_KEY: nil, OPENCODE_GO_API_KEY: nil do
      refute @provider.credential_configured?("openai/gpt-5-nano")
      refute @provider.credential_configured?("opencode_go/glm-5.3-flash")
    end

    refute @provider.credential_configured?("anthropic/claude-3-5-sonnet")
  end

  test "api_key_for prefers the environment when both the environment and encrypted credentials are present" do
    with_credentials("OPENAI_API_KEY" => "credential-key") do
      with_env_overrides OPENAI_API_KEY: "env-key" do
        assert_equal "env-key", Provider::RubyLlm::Catalog.api_key_for("OPENAI_API_KEY")
      end
    end
  end

  test "api_key_for falls back to encrypted Rails credentials when the environment variable is absent" do
    with_credentials("OPENAI_API_KEY" => "credential-key") do
      with_env_overrides OPENAI_API_KEY: nil do
        assert_equal "credential-key", Provider::RubyLlm::Catalog.api_key_for("OPENAI_API_KEY")
      end
    end
  end

  test "api_key_for returns nil when neither the environment nor encrypted credentials provide a key" do
    with_credentials({}) do
      with_env_overrides OPENAI_API_KEY: nil, OPENCODE_GO_API_KEY: nil do
        assert_nil Provider::RubyLlm::Catalog.api_key_for("OPENAI_API_KEY")
      end
    end
  end

  test "credential_configured? and credentials_configured? accept a key supplied only by encrypted Rails credentials" do
    with_credentials("OPENAI_API_KEY" => "credential-key") do
      with_env_overrides OPENAI_API_KEY: nil, OPENCODE_GO_API_KEY: nil do
        assert @provider.credential_configured?("openai/gpt-5-nano")
        refute @provider.credential_configured?("opencode_go/glm-5.3-flash")
        assert @provider.credentials_configured?
      end
    end
  end

  test "registry valid_llm_model? accepts a key supplied only by encrypted Rails credentials" do
    Provider::RubyLlm::Catalog.any_instance.stubs(:available?).returns(true)

    with_credentials("OPENAI_API_KEY" => "credential-key") do
      with_env_overrides OPENAI_API_KEY: nil, OPENCODE_GO_API_KEY: nil do
        assert Provider::Registry.valid_llm_model?("openai/gpt-5-nano")
      end
    end
  end

  test "registry valid_llm_model? returns false without consulting the live catalog when no key is configured" do
    Provider::RubyLlm::Catalog.any_instance.expects(:available?).never

    with_credentials({}) do
      with_env_overrides OPENAI_API_KEY: nil, OPENCODE_GO_API_KEY: nil do
        refute Provider::Registry.valid_llm_model?("openai/gpt-5-nano")
      end
    end
  end

  test "chat_response fails closed when neither the environment nor encrypted credentials provide a key" do
    with_credentials({}) do
      with_env_overrides OPENAI_API_KEY: nil, OPENCODE_GO_API_KEY: nil do
        @response = @provider.chat_response("Hello", model: "openai/gpt-5-nano")
      end
    end

    refute @response.success?
    assert_kind_of Provider::RubyLlm::Error, @response.error
    assert_match(/OPENAI_API_KEY/, @response.error.message)
    refute_match(/credential-key/, @response.error.message)
  end

  test "admits openai/gpt-5-nano with a valid live model list and passes it to RubyLLM with assume_model_exists: true" do
    final_message = FakeMessage.new(content: "Your net worth is $50,000.", id: "msg_1")
    chat = FakeChat.new(final_message: final_message)
    config, context = stub_ruby_llm_context(chat)

    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano"), model_entry("gpt-4o") ], auth_key: "test-openai-key")

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.chat_response("What is my net worth?", model: "openai/gpt-5-nano")
    end

    assert @response.success?
    assert_nil @response.error

    data = @response.data
    assert_instance_of Provider::LlmConcept::ChatResponse, data
    assert_equal "msg_1", data.id
    assert_equal "openai/gpt-5-nano", data.model
    assert_equal 1, data.messages.size
    assert_instance_of Provider::LlmConcept::ChatMessage, data.messages.first
    assert_equal "Your net worth is $50,000.", data.messages.first.output_text
    assert_equal [], data.function_requests

    # Isolated per-call config: normal OpenAI base and key from OPENAI_API_KEY.
    assert_equal "test-openai-key", config.openai_api_key
    assert_equal Provider::RubyLlm::OPENAI_BASE_URL, config.openai_api_base

    # Catalog admission always passes assume_model_exists: true; RubyLLM's
    # bundled 1.16 registry is never consulted for admission.
    assert_equal({ model: "gpt-5-nano", provider: :openai, protocol: :chat_completions, assume_model_exists: true }, context.chat_options)

    assert_equal "What is my net worth?", chat.prompt
    assert_nil chat.instructions
  end

  test "intersects the manifest with the live model list and rejects catalogued models missing from it" do
    RubyLLM.expects(:context).never

    stub_live_models(:openai, entries: [ model_entry("gpt-4o") ], auth_key: "test-openai-key")

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.chat_response("Hello", model: "openai/gpt-5-nano")
    end

    refute @response.success?
    assert_nil @response.data
    assert_kind_of Provider::RubyLlm::Error, @response.error
    assert_match(/openai\/gpt-5-nano/, @response.error.message)
    assert_match(/live openai model list/, @response.error.message)
    assert_equal "openai/gpt-5-nano", @response.error.details[:model]
    assert_equal false, @response.error.details[:retryable]
  end

  test "never admits an ID merely because it appears in the live model list" do
    RubyLLM.expects(:context).never

    stub_live_models(:openai, entries: [ model_entry("o3-pro"), model_entry("made-up-live-model") ], auth_key: "test-openai-key")

    [ "openai/o3-pro", "openai/made-up-live-model" ].each do |reference|
      @response = @provider.chat_response("Hello", model: reference)

      refute @response.success?, "expected #{reference.inspect} to be rejected"
      assert_kind_of Provider::RubyLlm::Error, @response.error
      assert_match(/#{Regexp.escape(reference)}/, @response.error.message)
    end
  end

  test "excludes OpenAI models whose shutdown_date is in the past" do
    past_shutdown_chat = FakeChat.new(final_message: FakeMessage.new(content: "Hi", id: "msg_past"))
    past_config = FakeConfig.new
    RubyLLM.stubs(:context).yields(past_config).returns(FakeContext.new(past_shutdown_chat))

    stub_live_models(:openai, entries: [ model_entry("gpt-4o", shutdown_date: (Date.current - 30).iso8601) ], auth_key: "test-openai-key")

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.chat_response("Hello", model: "openai/gpt-4o")
    end

    refute @response.success?
    assert_kind_of Provider::RubyLlm::Error, @response.error
    assert_match(/openai\/gpt-4o/, @response.error.message)
    assert_match(/live openai model list/, @response.error.message)

    # A future shutdown_date does not exclude the model, and a missing
    # shutdown_date never excludes one.
    [ Date.current + 365, nil ].each do |shutdown_date|
      future_chat = FakeChat.new(final_message: FakeMessage.new(content: "Hi", id: "msg_future"))
      future_config = FakeConfig.new
      RubyLLM.stubs(:context).yields(future_config).returns(FakeContext.new(future_chat))

      entry = shutdown_date ? model_entry("gpt-4o", shutdown_date: shutdown_date.iso8601) : model_entry("gpt-4o")
      stub_live_models(:openai, entries: [ entry ], auth_key: "test-openai-key")

      # Live availability is memoized per provider instance (one live request
      # per admission cycle), so each case uses a fresh instance.
      with_env_overrides OPENAI_API_KEY: "test-openai-key" do
        @response = Provider::RubyLlm.new.chat_response("Hello", model: "openai/gpt-4o")
      end

      assert @response.success?, "expected openai/gpt-4o with shutdown_date #{shutdown_date.inspect} to be admitted"
    end
  end

  test "rejects the stale grok-4-fast reference even when the live Go list returns it" do
    RubyLLM.expects(:context).never

    stub_live_models(:opencode_go, entries: [ model_entry("grok-4-fast"), model_entry("glm-5.3-flash") ], auth_key: "test-go-key")

    with_env_overrides OPENCODE_GO_API_KEY: "test-go-key" do
      @response = @provider.chat_response("Hello", model: "opencode_go/grok-4-fast")
    end

    refute @response.success?
    assert_nil @response.data
    assert_kind_of Provider::RubyLlm::Error, @response.error
    assert_match(/opencode_go\/grok-4-fast/, @response.error.message)
    assert_match(/opencode_go\/glm-5.3-flash/, @response.error.message)
    assert_equal "opencode_go/grok-4-fast", @response.error.details[:model]
    assert_equal "opencode_go", @response.error.details[:provider_reference]
  end

  test "sends the OpenCode Go Bearer key on the live catalog request for forward compatibility" do
    final_message = FakeMessage.new(content: "Hello from Go.")
    chat = FakeChat.new(final_message: final_message)
    stub_ruby_llm_context(chat)

    stub_live_models(:opencode_go, entries: [ model_entry("glm-5.3-flash") ], auth_key: "test-go-key")

    with_env_overrides OPENCODE_GO_API_KEY: "test-go-key" do
      @response = @provider.chat_response("Hello", model: "opencode_go/glm-5.3-flash")
    end

    assert @response.success?
  end

  test "fails closed with a provider error when the live catalog request fails" do
    RubyLLM.expects(:context).never

    stub_request(:get, OPENAI_MODELS_URL)
      .with(headers: { "Accept" => "application/json", "Authorization" => "Bearer test-openai-key" })
      .to_return(status: 500, body: "boom")

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.chat_response("Hello", model: "openai/gpt-5-nano")
    end

    refute @response.success?
    assert_nil @response.data
    assert_kind_of Provider::RubyLlm::Error, @response.error
    # No silent fallback to the manifest: an admitted-in-manifest model is
    # still rejected when the live catalog request fails.
    assert_match(/catalog request for account 'openai' failed/i, @response.error.message)
    assert_equal "openai/gpt-5-nano", @response.error.details[:model]
    assert_equal "Faraday::ServerError", @response.error.details[:error_class]
    assert_equal true, @response.error.details[:retryable]
    assert_equal 500, @response.error.details[:http_status]
  end

  test "propagates catalog rate limiting as a retryable provider error for both accounts" do
    {
      openai: [ OPENAI_MODELS_URL, "OPENAI_API_KEY", "test-openai-key", "openai/gpt-5-nano" ],
      opencode_go: [ OPENCODE_GO_MODELS_URL, "OPENCODE_GO_API_KEY", "test-go-key", "opencode_go/glm-5.3-flash" ]
    }.each do |account, (url, credential, token, reference)|
      stub_request(:get, url)
        .to_return(
          status: 429,
          headers: { "Content-Type" => "application/json" },
          body: { "error" => { "message" => "SECRET-CATALOG-BODY" } }.to_json
        )

      response = nil
      with_env_overrides(credential => token) do
        response = @provider.chat_response("Hello", model: reference)
      end

      refute response.success?, "expected #{account} rate limiting to fail closed"
      assert_nil response.data
      assert_kind_of Provider::RubyLlm::Error, response.error
      assert_match(/catalog request for account '#{account}' failed/i, response.error.message)
      assert_equal reference, response.error.details[:model]
      assert_equal account.to_s, response.error.details[:provider_reference]
      assert_equal "Faraday::TooManyRequestsError", response.error.details[:error_class]
      assert_equal true, response.error.details[:retryable]
      assert_equal 429, response.error.details[:http_status]
      refute_match(/SECRET-CATALOG-BODY/, response.error.message)
      assert_requested :get, url, times: 1
    end
  end

  test "propagates catalog timeouts as retryable provider errors without a status for both accounts" do
    {
      openai: [ OPENAI_MODELS_URL, "OPENAI_API_KEY", "test-openai-key", "openai/gpt-5-nano" ],
      opencode_go: [ OPENCODE_GO_MODELS_URL, "OPENCODE_GO_API_KEY", "test-go-key", "opencode_go/glm-5.3-flash" ]
    }.each do |account, (url, credential, token, reference)|
      stub_request(:get, url).to_timeout

      response = nil
      with_env_overrides(credential => token) do
        response = @provider.chat_response("Hello", model: reference)
      end

      refute response.success?, "expected #{account} timeout to fail closed"
      assert_nil response.data
      assert_kind_of Provider::RubyLlm::Error, response.error
      assert_equal reference, response.error.details[:model]
      assert_equal account.to_s, response.error.details[:provider_reference]
      # Net::HTTP's open timeout surfaces through Faraday as a connection
      # failure; either transport timeout class must stay retryable.
      assert_includes %w[Faraday::TimeoutError Faraday::ConnectionFailed], response.error.details[:error_class]
      assert_equal true, response.error.details[:retryable]
      assert_nil response.error.details[:http_status]
      assert_requested :get, url, times: 1
    end
  end

  test "fails closed when the live catalog response has an unexpected shape" do
    RubyLLM.expects(:context).never

    stub_request(:get, OPENCODE_GO_MODELS_URL)
      .with(headers: { "Accept" => "application/json", "Authorization" => "Bearer test-go-key" })
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: { object: "list" }.to_json)

    with_env_overrides OPENCODE_GO_API_KEY: "test-go-key" do
      @response = @provider.chat_response("Hello", model: "opencode_go/glm-5.3-flash")
    end

    refute @response.success?
    assert_kind_of Provider::RubyLlm::Error, @response.error
    assert_match(/unexpected model catalog response shape for account 'opencode_go'/i, @response.error.message)
    assert_equal "Provider::RubyLlm::Catalog::Error", @response.error.details[:error_class]
    assert_equal false, @response.error.details[:retryable]
    assert_nil @response.error.details[:http_status]
  end

  test "keeps inherited OpenAI organization and project headers on normal OpenAI calls" do
    final_message = FakeMessage.new(content: "Hi")
    chat = FakeChat.new(final_message: final_message)

    config = FakeConfig.new
    config.openai_organization_id = "org-inherited"
    config.openai_project_id = "proj-inherited"
    stub_ruby_llm_context(chat, config: config)

    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.chat_response("Hello", model: "openai/gpt-5-nano")
    end

    assert @response.success?
    # Normal OpenAI calls keep the deployment's own billing identity.
    assert_equal "org-inherited", config.openai_organization_id
    assert_equal "proj-inherited", config.openai_project_id
  end

  test "clears inherited OpenAI organization and project headers only for OpenCode Go calls" do
    final_message = FakeMessage.new(content: "Hi")
    chat = FakeChat.new(final_message: final_message)

    config = FakeConfig.new
    config.openai_organization_id = "org-inherited"
    config.openai_project_id = "proj-inherited"
    stub_ruby_llm_context(chat, config: config)

    stub_live_models(:opencode_go, entries: [ model_entry("glm-5.3-flash") ], auth_key: "test-go-key")

    with_env_overrides OPENCODE_GO_API_KEY: "test-go-key" do
      @response = @provider.chat_response("Hello", model: "opencode_go/glm-5.3-flash")
    end

    assert @response.success?
    assert_nil config.openai_organization_id
    assert_nil config.openai_project_id
  end

  test "forwards instructions to the RubyLLM chat as system instructions" do
    final_message = FakeMessage.new(content: "Sure.", id: "msg_2")
    chat = FakeChat.new(final_message: final_message)
    stub_ruby_llm_context(chat)

    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.chat_response("Hello", model: "openai/gpt-5-nano", instructions: "You are a helpful assistant.")
    end

    assert @response.success?
    assert_equal "You are a helpful assistant.", chat.instructions
  end

  test "streams text chunks and a final response chunk through the existing streamer contract" do
    final_message = FakeMessage.new(content: "Hello world", id: "msg_stream")
    chat = FakeChat.new(
      final_message: final_message,
      chunks: [ FakeChunk.new(content: "Hello "), FakeChunk.new(content: "world") ]
    )
    stub_ruby_llm_context(chat)

    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")

    collected = []
    streamer = proc { |chunk| collected << chunk }

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.chat_response("Hello", model: "openai/gpt-5-nano", streamer: streamer)
    end

    assert @response.success?
    text_chunks = collected.select { |chunk| chunk.type == "output_text" }
    response_chunks = collected.select { |chunk| chunk.type == "response" }
    assert_equal [ "Hello ", "world" ], text_chunks.map(&:data)
    assert_equal 1, response_chunks.size
    assert_instance_of Provider::LlmConcept::ChatStreamChunk, response_chunks.first
    assert_equal @response.data, response_chunks.first.data
  end

  test "generates a fresh synthetic response id per call on the same provider instance" do
    final_message = FakeMessage.new(content: "Hi")
    chat = FakeChat.new(final_message: final_message)
    stub_ruby_llm_context(chat)

    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @first = @provider.chat_response("Hello", model: "openai/gpt-5-nano")
      @second = @provider.chat_response("Hello", model: "openai/gpt-5-nano")
    end

    assert @first.success?
    assert @second.success?
    assert @first.data.id.present?
    assert @second.data.id.present?
    refute_equal @first.data.id, @second.data.id
  end

  test "returns a provider error envelope for unknown provider prefixes" do
    @response = @provider.chat_response("Hello", model: "anthropic/claude-3-5-sonnet")

    refute @response.success?
    assert_nil @response.data
    assert_kind_of Provider::RubyLlm::Error, @response.error
    assert_match(/anthropic/, @response.error.message)
    assert_equal "anthropic", @response.error.details[:provider_reference]
    assert_equal "anthropic/claude-3-5-sonnet", @response.error.details[:model]
    assert_equal "Provider::RubyLlm::Error", @response.error.details[:error_class]
    assert_equal false, @response.error.details[:retryable]
  end

  test "returns a clear provider error envelope when credentials are missing" do
    with_env_overrides OPENAI_API_KEY: nil, OPENCODE_GO_API_KEY: nil do
      @response = @provider.chat_response("Hello", model: "openai/gpt-5-nano")
    end

    refute @response.success?
    assert_kind_of Provider::RubyLlm::Error, @response.error
    assert_match(/OPENAI_API_KEY/, @response.error.message)
    assert_equal "openai/gpt-5-nano", @response.error.details[:model]

    with_env_overrides OPENAI_API_KEY: nil, OPENCODE_GO_API_KEY: nil do
      @response = @provider.chat_response("Hello", model: "opencode_go/glm-5.3-flash")
    end

    refute @response.success?
    assert_match(/OPENCODE_GO_API_KEY/, @response.error.message)
    assert_equal "opencode_go/glm-5.3-flash", @response.error.details[:model]
  end

  test "rejects malformed, URL, extra-segment, unsupported, and unadmitted references before creating a chat" do
    invalid_references = [
      "gpt-5-nano",
      "openai/",
      "/gpt-5-nano",
      "openai//gpt-5-nano",
      "openai/gpt-5-nano/extra",
      "opencode_go/glm-5.3-flash/",
      "https://api.openai.com/v1",
      "openai/https://example.com/gpt-5-nano",
      "opencode_go://glm-5.3-flash",
      "anthropic/claude-3-5-sonnet",
      "opencode/big-pickle",
      "openai/does-not-exist",
      "opencode_go/grok-4-fast",
      nil,
      ""
    ]

    RubyLLM.expects(:context).never

    invalid_references.each do |reference|
      @response = @provider.chat_response("Hello", model: reference)

      refute @response.success?, "expected #{reference.inspect} to be rejected"
      assert_nil @response.data
      assert_kind_of Provider::RubyLlm::Error, @response.error
    end
  end

  test "keeps openai and opencode_go contexts isolated in one process" do
    openai_chat = FakeChat.new(final_message: FakeMessage.new(content: "OpenAI answer.", id: "msg_openai"))
    go_chat = FakeChat.new(final_message: FakeMessage.new(content: "Go answer.", id: "msg_go"))
    openai_config = FakeConfig.new
    go_config = FakeConfig.new
    openai_context = FakeContext.new(openai_chat)
    go_context = FakeContext.new(go_chat)

    RubyLLM.stubs(:context)
      .yields(openai_config).returns(openai_context)
      .then.yields(go_config).returns(go_context)

    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "openai-key-1")
    stub_live_models(:opencode_go, entries: [ model_entry("glm-5.3-flash") ], auth_key: "go-key-1")

    with_env_overrides OPENAI_API_KEY: "openai-key-1", OPENCODE_GO_API_KEY: "go-key-1" do
      @openai_response = @provider.chat_response("Hello", model: "openai/gpt-5-nano")
      @go_response = @provider.chat_response("Hello", model: "opencode_go/glm-5.3-flash")
    end

    assert @openai_response.success?
    assert @go_response.success?

    # The OpenAI call never sees the Go key/base and vice versa.
    assert_equal "openai-key-1", openai_config.openai_api_key
    assert_equal Provider::RubyLlm::OPENAI_BASE_URL, openai_config.openai_api_base
    assert_equal({ model: "gpt-5-nano", provider: :openai, protocol: :chat_completions, assume_model_exists: true }, openai_context.chat_options)
    assert_equal "go-key-1", go_config.openai_api_key
    assert_equal Provider::RubyLlm::OPENCODE_GO_BASE_URL, go_config.openai_api_base
    assert_equal({ model: "glm-5.3-flash", provider: :openai, protocol: :chat_completions, assume_model_exists: true }, go_context.chat_options)

    # Billing metadata never crosses: each reference resolves to its own
    # account through the catalog.
    assert_equal "openai", Provider::RubyLlm.supported_models.fetch("openai/gpt-5-nano")[:billing_account]
    assert_equal "opencode_go", Provider::RubyLlm.supported_models.fetch("opencode_go/glm-5.3-flash")[:billing_account]
  end

  test "keeps per-call provider contexts isolated from the global RubyLLM config" do
    final_message = FakeMessage.new(content: "Hi")
    chat = FakeChat.new(final_message: final_message)
    stub_ruby_llm_context(chat)

    stub_live_models(:opencode_go, entries: [ model_entry("glm-5.3-flash") ], auth_key: "test-go-key")

    with_env_overrides OPENCODE_GO_API_KEY: "test-go-key" do
      @response = @provider.chat_response("Hello", model: "opencode_go/glm-5.3-flash")
    end

    assert @response.success?
    # The per-call context receives the Go key/base; the global config is never
    # mutated, so its provider options stay at their defaults.
    assert_nil RubyLLM.config.openai_api_key
    assert_nil RubyLLM.config.openai_api_base
  end

  test "never refreshes or mutates the global RubyLLM model registry" do
    RubyLLM::Models.expects(:refresh!).never

    global_models = mock("ruby_llm_models")
    global_models.expects(:refresh!).never
    RubyLLM.stubs(:models).returns(global_models)

    final_message = FakeMessage.new(content: "Hi")
    chat = FakeChat.new(final_message: final_message)
    stub_ruby_llm_context(chat)

    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.chat_response("Hello", model: "openai/gpt-5-nano")
    end

    assert @response.success?
  end

  test "maps RubyLLM API errors to a safe provider error without key or prompt leakage" do
    chat = FakeChat.new(final_message: nil)
    chat.stubs(:ask).raises(RubyLLM::UnauthorizedError, "Incorrect API key provided: sk-test-secret-123")
    stub_ruby_llm_context(chat)

    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.chat_response("What is my net worth?", model: "openai/gpt-5-nano")
    end

    refute @response.success?
    assert_nil @response.data
    assert_kind_of Provider::RubyLlm::Error, @response.error
    assert_equal "openai", @response.error.details[:provider_reference]
    assert_equal "openai/gpt-5-nano", @response.error.details[:model]
    assert_equal "RubyLLM::UnauthorizedError", @response.error.details[:error_class]
    assert_equal false, @response.error.details[:retryable]
    refute_match(/sk-test-secret-123/, @response.error.message)
    refute_match(/What is my net worth/, @response.error.message)
  end

  test "marks rate limit and connection failures as retryable in the error details" do
    chat = FakeChat.new(final_message: nil)
    chat.stubs(:ask).raises(RubyLLM::RateLimitError, "Rate limit exceeded")
    stub_ruby_llm_context(chat)

    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.chat_response("Hello", model: "openai/gpt-5-nano")
    end

    refute @response.success?
    assert_equal "RubyLLM::RateLimitError", @response.error.details[:error_class]
    assert_equal true, @response.error.details[:retryable]
  end

  test "rejects uncatalogued OpenAI references with a clear error before any catalog request" do
    RubyLLM.expects(:context).never

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.chat_response("Hello", model: "openai/does-not-exist")
    end

    refute @response.success?
    assert_nil @response.data
    assert_kind_of Provider::RubyLlm::Error, @response.error
    assert_match(/openai\/does-not-exist/, @response.error.message)
    assert_match(/openai\/gpt-5-nano/, @response.error.message)
    assert_equal "openai/does-not-exist", @response.error.details[:model]
    assert_equal "openai", @response.error.details[:provider_reference]
    assert_equal "Provider::RubyLlm::Error", @response.error.details[:error_class]
    assert_equal false, @response.error.details[:retryable]
  end

  test "registry routes the llm concept to RubyLLM regardless of the legacy provider toggle" do
    [ nil, "opencode", "ruby_llm" ].each do |value|
      with_env_overrides KURIA_LLM_PROVIDER: value do
        provider_classes = Provider::Registry.for_concept(:llm).providers.map(&:class)

        assert_equal [ Provider::RubyLlm ], provider_classes
      end
    end
  end

  test "registry resolves the ruby_llm provider directly" do
    with_env_overrides KURIA_LLM_PROVIDER: nil do
      assert_instance_of Provider::RubyLlm, Provider::Registry.get_provider(:ruby_llm)
    end
  end

  # --- merchant detection and suggestion (#30) structured output -----------

  test "auto_detect_merchants sends the strict JSON schema with preserved enums and normalizes valid results" do
    content = {
      "merchants" => [
        { "transaction_id" => "1", "business_name" => "McDonald's", "business_url" => "mcdonalds.com" },
        { "transaction_id" => "2", "business_name" => "null", "business_url" => "null" }
      ]
    }
    chat = FakeChat.new(final_message: FakeMessage.new(content: content))
    stub_ruby_llm_context(chat)

    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")

    transactions = [ { id: "1", description: "McDonalds" }, { id: "2", description: "generic" } ]
    user_merchants = [ { id: "m1", name: "Shooters" } ]

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.auto_detect_merchants(
        transactions: transactions, user_merchants: user_merchants, model: "openai/gpt-5-nano"
      )
    end

    assert @response.success?
    assert_nil @response.error

    results = @response.data
    assert_equal 2, results.size
    assert_instance_of Provider::LlmConcept::AutoDetectedMerchant, results.first
    assert_equal "McDonald's", results.first.business_name
    assert_equal "mcdonalds.com", results.first.business_url
    # Explicit null is encoded as the enum member "null" and normalizes to nil.
    assert_nil results.last.business_name
    assert_nil results.last.business_url

    wrapper = chat.schema
    assert_equal "auto_detect_merchants", wrapper[:name]
    assert_equal true, wrapper[:strict]

    schema = wrapper[:schema]
    refute schema.key?(:strict)
    assert_equal %w[merchants], schema[:required]
    assert_equal false, schema[:additionalProperties]

    items = schema.dig(:properties, :merchants, :items)
    assert_equal %w[transaction_id business_name business_url], items[:required]
    assert_equal false, items[:additionalProperties]
    assert_equal %w[1 2], items.dig(:properties, :transaction_id, :enum)
    assert_equal %w[string null], items.dig(:properties, :business_name, :type)
    assert_equal %w[string null], items.dig(:properties, :business_url, :type)
  end

  test "auto_detect_merchants preserves unknown and extra transaction ids for the domain to ignore" do
    content = {
      "merchants" => [
        { "transaction_id" => "unknown", "business_name" => "Ghost", "business_url" => "ghost.com" },
        { "transaction_id" => "1", "business_name" => "McDonald's", "business_url" => "mcdonalds.com" }
      ]
    }
    chat = FakeChat.new(final_message: FakeMessage.new(content: content))
    stub_ruby_llm_context(chat)
    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.auto_detect_merchants(
        transactions: [ { id: "1" } ], user_merchants: [], model: "openai/gpt-5-nano"
      )
    end

    assert @response.success?
    assert_equal [ "unknown", "1" ], @response.data.map(&:transaction_id)
    assert @response.data.all? { |result| result.is_a?(Provider::LlmConcept::AutoDetectedMerchant) }
  end

  test "auto_detect_merchants fails closed on malformed entries rather than accepting them" do
    cases = {
      missing_transaction_id: [ { "business_name" => "McDonald's", "business_url" => "mcdonalds.com" } ],
      missing_business_name: [ { "transaction_id" => "1", "business_url" => "mcdonalds.com" } ],
      missing_business_url: [ { "transaction_id" => "1", "business_name" => "McDonald's" } ],
      business_name_wrong_type: [ { "transaction_id" => "1", "business_name" => 5, "business_url" => "mcdonalds.com" } ],
      business_url_wrong_type: [ { "transaction_id" => "1", "business_name" => "McDonald's", "business_url" => [ "mcdonalds.com" ] } ],
      duplicate_transaction_ids: [
        { "transaction_id" => "1", "business_name" => "McDonald's", "business_url" => "mcdonalds.com" },
        { "transaction_id" => "1", "business_name" => nil, "business_url" => nil }
      ]
    }

    cases.each do |label, entries|
      stub_ruby_llm_context(FakeChat.new(final_message: FakeMessage.new(content: { "merchants" => entries })))
      stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")

      response = nil
      with_env_overrides OPENAI_API_KEY: "test-openai-key" do
        response = Provider::RubyLlm.new.auto_detect_merchants(
          transactions: [ { id: "1" } ], user_merchants: [], model: "openai/gpt-5-nano"
        )
      end

      refute response.success?, "expected #{label} to fail closed"
      assert_nil response.data
      assert_kind_of Provider::RubyLlm::Error, response.error
    end
  end

  test "auto_detect_merchants fails closed when transaction_id is an Integer instead of a String" do
    content = { "merchants" => [ { "transaction_id" => 1, "business_name" => "McDonald's", "business_url" => "mcdonalds.com" } ] }

    stub_ruby_llm_context(FakeChat.new(final_message: FakeMessage.new(content: content)))
    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")

    response = nil
    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      response = Provider::RubyLlm.new.auto_detect_merchants(
        transactions: [ { id: "1" } ], user_merchants: [], model: "openai/gpt-5-nano"
      )
    end

    refute response.success?, "expected an Integer transaction_id to fail closed"
    assert_nil response.data
    assert_kind_of Provider::RubyLlm::Error, response.error
  end

  test "auto_detect_merchants canonicalizes integer input ids outbound and restores original ids in results" do
    content = { "merchants" => [ { "transaction_id" => "42", "business_name" => "McDonald's", "business_url" => "mcdonalds.com" } ] }
    chat = FakeChat.new(final_message: FakeMessage.new(content: content))
    stub_ruby_llm_context(chat)
    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")

    transactions = [ { id: 42, description: "McDonalds" } ]
    user_merchants = [ { id: 7, name: "Shooters" } ]

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.auto_detect_merchants(transactions: transactions, user_merchants: user_merchants, model: "openai/gpt-5-nano")
    end

    assert @response.success?
    assert_equal 42, @response.data.first.transaction_id
    assert_kind_of Integer, @response.data.first.transaction_id

    enum = chat.schema.dig(:schema, :properties, :merchants, :items, :properties, :transaction_id, :enum)
    assert_equal [ "42" ], enum
    assert enum.all? { |value| value.is_a?(String) }

    assert_includes chat.prompt, "\"id\":\"42\""
    refute_includes chat.prompt, "\"id\":42"
    # Detection prompt lists user merchants with canonical String ids too.
    assert_includes chat.prompt, "\"id\":\"7\""

    assert_equal 42, transactions.first[:id]
    assert_equal 7, user_merchants.first[:id]
  end

  test "auto_detect_merchants fails closed on malformed, refused, or shapeless structured output" do
    cases = {
      malformed_json: FakeMessage.new(content: "this is not json"),
      provider_refusal: FakeMessage.new(content: nil),
      missing_array: FakeMessage.new(content: { "unexpected" => [] }),
      non_array: FakeMessage.new(content: { "merchants" => "nope" }),
      non_object_entries: FakeMessage.new(content: { "merchants" => [ "nope" ] })
    }

    cases.each do |label, final_message|
      stub_ruby_llm_context(FakeChat.new(final_message: final_message))
      stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")

      response = nil
      with_env_overrides OPENAI_API_KEY: "test-openai-key" do
        response = Provider::RubyLlm.new.auto_detect_merchants(
          transactions: [ { id: "1" } ], user_merchants: [], model: "openai/gpt-5-nano"
        )
      end

      refute response.success?, "expected #{label} to fail closed"
      assert_nil response.data
      assert_kind_of Provider::RubyLlm::Error, response.error
    end
  end

  test "auto_detect_merchants fails closed when the batch exceeds the legacy limit" do
    RubyLLM.expects(:context).never

    transactions = Array.new(Provider::RubyLlm::MAX_ENRICHMENT_TRANSACTIONS + 1) { |i| { id: i.to_s } }

    response = @provider.auto_detect_merchants(transactions: transactions, user_merchants: [], model: "openai/gpt-5-nano")

    refute response.success?
    assert_nil response.data
    assert_kind_of Provider::RubyLlm::Error, response.error
    assert_match(/Too many transactions to auto-detect merchants/, response.error.message)
  end

  test "auto_detect_merchants fails closed without touching RubyLLM when the explicit model reference is blank or unsupported" do
    RubyLLM.expects(:context).never

    [ nil, "", "openai/does-not-exist", "anthropic/claude-3-5-sonnet" ].each do |reference|
      response = @provider.auto_detect_merchants(transactions: [ { id: "1" } ], user_merchants: [], model: reference)

      refute response.success?, "expected #{reference.inspect} to fail"
      assert_nil response.data
      assert_kind_of Provider::RubyLlm::Error, response.error
    end
  end

  test "suggest_merchant sends the strict JSON schema and normalizes a structured suggestion" do
    content = { "merchant_id" => "m1", "confidence" => 0.82, "rationale" => "Matches the normalized name." }
    chat = FakeChat.new(final_message: FakeMessage.new(content: content))
    stub_ruby_llm_context(chat)

    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")

    user_merchants = [ { id: "m1", name: "Shooters" } ]

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.suggest_merchant(
        raw_name: "SHOOTERS BAR", normalized_name: "shooters bar", user_merchants: user_merchants, model: "openai/gpt-5-nano"
      )
    end

    assert @response.success?
    assert_instance_of Provider::LlmConcept::MerchantSuggestion, @response.data
    assert_equal "m1", @response.data.merchant_id
    assert_in_delta 0.82, @response.data.confidence, 0.0001
    assert_equal "Matches the normalized name.", @response.data.rationale

    wrapper = chat.schema
    assert_equal "suggest_merchant", wrapper[:name]
    assert_equal true, wrapper[:strict]

    schema = wrapper[:schema]
    refute schema.key?(:strict)
    assert_equal %w[merchant_id confidence rationale], schema[:required]
    assert_equal false, schema[:additionalProperties]
    assert_equal %w[string null], schema.dig(:properties, :merchant_id, :type)
    assert_equal "number", schema.dig(:properties, :confidence, :type)
    assert_equal "string", schema.dig(:properties, :rationale, :type)

    assert_includes chat.prompt, "SHOOTERS BAR"
    assert_includes chat.prompt, user_merchants.to_json
  end

  test "suggest_merchant normalizes an explicit null merchant_id to no suggestion" do
    chat = FakeChat.new(final_message: FakeMessage.new(content: { "merchant_id" => nil, "confidence" => 0.0, "rationale" => "" }))
    stub_ruby_llm_context(chat)
    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.suggest_merchant(
        raw_name: "UNKNOWN", normalized_name: "unknown", user_merchants: [], model: "openai/gpt-5-nano"
      )
    end

    assert @response.success?
    assert_nil @response.data.merchant_id
    assert_equal 0.0, @response.data.confidence
    assert_equal "", @response.data.rationale
  end

  test "suggest_merchant normalizes the explicit-null sentinel merchant_id to no suggestion" do
    chat = FakeChat.new(final_message: FakeMessage.new(content: { "merchant_id" => "null", "confidence" => 0.4, "rationale" => "unsure" }))
    stub_ruby_llm_context(chat)
    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.suggest_merchant(
        raw_name: "UNKNOWN", normalized_name: "unknown", user_merchants: [], model: "openai/gpt-5-nano"
      )
    end

    assert @response.success?
    assert_nil @response.data.merchant_id
  end

  test "suggest_merchant fails closed on missing, wrong-typed, or unadmitted required fields" do
    merchants = [ { id: "m1", name: "Shooters" } ]

    cases = {
      missing_merchant_id: { content: { "confidence" => 0.5, "rationale" => "x" }, merchants: merchants },
      missing_confidence: { content: { "merchant_id" => nil, "rationale" => "x" }, merchants: merchants },
      missing_rationale: { content: { "merchant_id" => nil, "confidence" => 0.5 }, merchants: merchants },
      merchant_id_not_admitted: { content: { "merchant_id" => "m-unknown", "confidence" => 0.9, "rationale" => "x" }, merchants: merchants },
      merchant_id_wrong_type: { content: { "merchant_id" => { "id" => "m1" }, "confidence" => 0.9, "rationale" => "x" }, merchants: merchants },
      confidence_string: { content: { "merchant_id" => nil, "confidence" => "0.9", "rationale" => "x" }, merchants: merchants },
      confidence_above_range: { content: { "merchant_id" => nil, "confidence" => 1.5, "rationale" => "x" }, merchants: merchants },
      confidence_below_range: { content: { "merchant_id" => nil, "confidence" => -0.1, "rationale" => "x" }, merchants: merchants },
      confidence_infinite: { content: { "merchant_id" => nil, "confidence" => Float::INFINITY, "rationale" => "x" }, merchants: merchants },
      confidence_nan: { content: { "merchant_id" => nil, "confidence" => Float::NAN, "rationale" => "x" }, merchants: merchants },
      rationale_wrong_type: { content: { "merchant_id" => nil, "confidence" => 0.5, "rationale" => 5 }, merchants: merchants }
    }

    cases.each do |label, spec|
      stub_ruby_llm_context(FakeChat.new(final_message: FakeMessage.new(content: spec[:content])))
      stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")

      response = nil
      with_env_overrides OPENAI_API_KEY: "test-openai-key" do
        response = Provider::RubyLlm.new.suggest_merchant(
          raw_name: "Acme", normalized_name: "acme", user_merchants: spec[:merchants], model: "openai/gpt-5-nano"
        )
      end

      refute response.success?, "expected #{label} to fail closed"
      assert_nil response.data
      assert_kind_of Provider::RubyLlm::Error, response.error
    end
  end

  test "suggest_merchant fails closed when merchant_id is an Integer instead of a String" do
    # "7" is admitted, but the response's integer 7 must not be coerced to it.
    merchants = [ { id: 7, name: "Shooters" } ]
    content = { "merchant_id" => 7, "confidence" => 0.9, "rationale" => "x" }

    stub_ruby_llm_context(FakeChat.new(final_message: FakeMessage.new(content: content)))
    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")

    response = nil
    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      response = Provider::RubyLlm.new.suggest_merchant(
        raw_name: "Acme", normalized_name: "acme", user_merchants: merchants, model: "openai/gpt-5-nano"
      )
    end

    refute response.success?, "expected an Integer merchant_id to fail closed"
    assert_nil response.data
    assert_kind_of Provider::RubyLlm::Error, response.error
  end

  test "suggest_merchant keeps an admitted String merchant id unchanged" do
    merchants = [ { id: "merchant-uuid", name: "Shooters" } ]
    content = { "merchant_id" => "merchant-uuid", "confidence" => 0.9, "rationale" => "x" }

    stub_ruby_llm_context(FakeChat.new(final_message: FakeMessage.new(content: content)))
    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")

    response = nil
    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      response = Provider::RubyLlm.new.suggest_merchant(
        raw_name: "Acme", normalized_name: "acme", user_merchants: merchants, model: "openai/gpt-5-nano"
      )
    end

    assert response.success?
    assert_equal "merchant-uuid", response.data.merchant_id
    assert_kind_of String, response.data.merchant_id
  end

  test "suggest_merchant canonicalizes integer merchant ids outbound and restores the original id in the result" do
    content = { "merchant_id" => "7", "confidence" => 0.9, "rationale" => "x" }
    chat = FakeChat.new(final_message: FakeMessage.new(content: content))
    stub_ruby_llm_context(chat)
    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")

    merchants = [ { id: 7, name: "Shooters" } ]

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.suggest_merchant(raw_name: "Acme", normalized_name: "acme", user_merchants: merchants, model: "openai/gpt-5-nano")
    end

    assert @response.success?
    assert_equal 7, @response.data.merchant_id
    assert_kind_of Integer, @response.data.merchant_id

    # Outbound prompt lists the merchant with a canonical String id.
    assert_includes chat.prompt, "\"id\":\"7\""
    refute_includes chat.prompt, "\"id\":7"
    assert_equal 7, merchants.first[:id]
  end

  test "provider validation errors never echo raw response values" do
    content = {
      "merchant_id" => "SECRET-MERCHANT-ID",
      "confidence" => "not-a-number-SECRET",
      "rationale" => "SECRET-RATIONALE"
    }

    stub_ruby_llm_context(FakeChat.new(final_message: FakeMessage.new(content: content)))
    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")

    response = nil
    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      response = Provider::RubyLlm.new.suggest_merchant(
        raw_name: "Acme", normalized_name: "acme", user_merchants: [], model: "openai/gpt-5-nano"
      )
    end

    refute response.success?
    assert_kind_of Provider::RubyLlm::Error, response.error
    refute_match(/SECRET-MERCHANT-ID/, response.error.message)
    refute_match(/SECRET-RATIONALE/, response.error.message)
    refute_match(/not-a-number-SECRET/, response.error.message)
  end

  test "suggest_merchant fails closed when confidence parses to a non-finite value from JSON" do
    # Ruby's JSON parser turns the JSON number 1e309 into Float::INFINITY, which
    # must not be accepted as a confidently-parsed suggestion.
    parsed = JSON.parse('{"merchant_id": null, "confidence": 1e309, "rationale": "x"}')
    assert_equal Float::INFINITY, parsed["confidence"]

    stub_ruby_llm_context(FakeChat.new(final_message: FakeMessage.new(content: parsed)))
    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")

    response = nil
    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      response = Provider::RubyLlm.new.suggest_merchant(
        raw_name: "Acme", normalized_name: "acme", user_merchants: [], model: "openai/gpt-5-nano"
      )
    end

    refute response.success?
    assert_nil response.data
    assert_kind_of Provider::RubyLlm::Error, response.error
  end

  test "suggest_merchant fails closed on malformed or refused structured output" do
    cases = {
      malformed_json: FakeMessage.new(content: "this is not json"),
      provider_refusal: FakeMessage.new(content: nil),
      non_object: FakeMessage.new(content: [ "nope" ])
    }

    cases.each do |label, final_message|
      stub_ruby_llm_context(FakeChat.new(final_message: final_message))
      stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")

      response = nil
      with_env_overrides OPENAI_API_KEY: "test-openai-key" do
        response = Provider::RubyLlm.new.suggest_merchant(
          raw_name: "Acme", normalized_name: "acme", user_merchants: [], model: "openai/gpt-5-nano"
        )
      end

      refute response.success?, "expected #{label} to fail closed"
      assert_nil response.data
      assert_kind_of Provider::RubyLlm::Error, response.error
    end
  end

  test "suggest_merchant fails closed without touching RubyLLM when the explicit model reference is blank or unsupported" do
    RubyLLM.expects(:context).never

    [ nil, "", "opencode_go/grok-4-fast", "anthropic/claude-3-5-sonnet" ].each do |reference|
      response = @provider.suggest_merchant(
        raw_name: "Acme", normalized_name: "acme", user_merchants: [], model: reference
      )

      refute response.success?, "expected #{reference.inspect} to fail"
      assert_nil response.data
      assert_kind_of Provider::RubyLlm::Error, response.error
    end
  end

  test "auto_detect_merchants sends the strict JSON schema over HTTP and parses the structured response through the real RubyLLM SDK" do
    chat_url = Provider::RubyLlm::OPENAI_BASE_URL + "/chat/completions"
    structured = { "merchants" => [ { "transaction_id" => "1", "business_name" => "McDonald's", "business_url" => "mcdonalds.com" } ] }

    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")

    stub_request(:post, chat_url)
      .with(headers: { "Authorization" => "Bearer test-openai-key" })
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          id: "chatcmpl-2",
          object: "chat.completion",
          created: 1,
          model: "gpt-5-nano",
          choices: [
            { index: 0, message: { role: "assistant", content: structured.to_json }, finish_reason: "stop" }
          ],
          usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
        }.to_json
      )

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.auto_detect_merchants(
        transactions: [ { id: "1", description: "McDonalds" } ], user_merchants: [], model: "openai/gpt-5-nano"
      )
    end

    assert @response.success?, "expected success, got: #{@response.error&.message}"
    assert_equal "McDonald's", @response.data.first.business_name

    assert_requested(:post, chat_url) do |request|
      body = JSON.parse(request.body)
      json_schema = body.dig("response_format", "json_schema")

      json_schema["name"] == "auto_detect_merchants" &&
        json_schema["strict"] == true &&
        json_schema["schema"]["additionalProperties"] == false &&
        json_schema["schema"]["properties"]["merchants"]["items"]["properties"]["business_name"]["type"] == %w[string null] &&
        json_schema["schema"]["properties"]["merchants"]["items"]["properties"]["transaction_id"]["enum"] == [ "1" ]
    end
  end

  # --- auto-categorization (#15) structured output -------------------------

  test "auto_detect_merchants canonicalizes integer ids over HTTP with a strict String schema and restores the original id" do
    chat_url = Provider::RubyLlm::OPENAI_BASE_URL + "/chat/completions"
    structured = { "merchants" => [ { "transaction_id" => "42", "business_name" => "McDonald's", "business_url" => "mcdonalds.com" } ] }

    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")

    stub_request(:post, chat_url)
      .with(headers: { "Authorization" => "Bearer test-openai-key" })
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          id: "chatcmpl-intmerchant",
          object: "chat.completion",
          created: 1,
          model: "gpt-5-nano",
          choices: [
            { index: 0, message: { role: "assistant", content: structured.to_json }, finish_reason: "stop" }
          ],
          usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 }
        }.to_json
      )

    transactions = [ { id: 42, description: "McDonalds" } ]

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.auto_detect_merchants(transactions: transactions, user_merchants: [], model: "openai/gpt-5-nano")
    end

    assert @response.success?, "expected success, got: #{@response.error&.message}"
    assert_equal 42, @response.data.first.transaction_id
    assert_kind_of Integer, @response.data.first.transaction_id

    assert_requested(:post, chat_url) do |request|
      body = JSON.parse(request.body)
      json_schema = body.dig("response_format", "json_schema")
      enum = json_schema.dig("schema", "properties", "merchants", "items", "properties", "transaction_id", "enum")

      json_schema["strict"] == true &&
        enum == [ "42" ] &&
        enum.all? { |value| value.is_a?(String) } &&
        !request.body.match?(/"enum":\[\s*\d/)
    end
  end

  test "auto_categorize sends the strict JSON schema with preserved enums and normalizes valid results" do
    content = {
      "categorizations" => [
        { "transaction_id" => "1", "category_name" => "Groceries" },
        { "transaction_id" => "2", "category_name" => "null" }
      ]
    }
    chat = FakeChat.new(final_message: FakeMessage.new(content: content))
    config, context = stub_ruby_llm_context(chat)

    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")

    transactions = [ { id: "1", description: "Whole Foods" }, { id: "2", description: "Mystery" } ]
    categories = [ { name: "Groceries" }, { name: "Dining" } ]

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.auto_categorize(transactions: transactions, user_categories: categories, model: "openai/gpt-5-nano")
    end

    assert @response.success?
    assert_nil @response.error

    results = @response.data
    assert_equal 2, results.size
    assert_instance_of Provider::LlmConcept::AutoCategorization, results.first
    assert_equal "1", results.first.transaction_id
    assert_equal "Groceries", results.first.category_name
    # Explicit null is encoded as the enum member "null" and normalizes to nil.
    assert_nil results.last.category_name

    # The explicit model reference resolves to the OpenAI account.
    assert_equal "test-openai-key", config.openai_api_key
    assert_equal Provider::RubyLlm::OPENAI_BASE_URL, config.openai_api_base
    assert_equal({ model: "gpt-5-nano", provider: :openai, protocol: :chat_completions, assume_model_exists: true }, context.chat_options)

    # Strict wrapper: name + schema + strict live at the wrapper level, never
    # `strict` inside the JSON schema definition.
    wrapper = chat.schema
    assert_equal "auto_categorize", wrapper[:name]
    assert_equal true, wrapper[:strict]

    schema = wrapper[:schema]
    refute schema.key?(:strict)
    assert_equal "object", schema[:type]
    assert_equal %w[categorizations], schema[:required]
    assert_equal false, schema[:additionalProperties]

    items = schema.dig(:properties, :categorizations, :items)
    assert_equal %w[transaction_id category_name], items[:required]
    assert_equal false, items[:additionalProperties]
    assert_equal %w[1 2], items.dig(:properties, :transaction_id, :enum)
    assert_equal [ "Groceries", "Dining", "null" ], items.dig(:properties, :category_name, :enum)

    assert_includes chat.instructions, "Return 1 result per transaction"
    assert_includes chat.prompt, transactions.to_json
    assert_includes chat.prompt, categories.to_json
  end

  test "auto_categorize preserves unknown and extra transaction ids for the domain to ignore" do
    content = {
      "categorizations" => [
        { "transaction_id" => "unknown", "category_name" => "Groceries" },
        { "transaction_id" => "1", "category_name" => "Dining" }
      ]
    }
    chat = FakeChat.new(final_message: FakeMessage.new(content: content))
    stub_ruby_llm_context(chat)

    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.auto_categorize(
        transactions: [ { id: "1" } ],
        user_categories: [ { name: "Groceries" }, { name: "Dining" } ],
        model: "openai/gpt-5-nano"
      )
    end

    assert @response.success?
    assert_equal [ "unknown", "1" ], @response.data.map(&:transaction_id)
    assert_equal [ "Groceries", "Dining" ], @response.data.map(&:category_name)
    assert @response.data.all? { |result| result.is_a?(Provider::LlmConcept::AutoCategorization) }
  end

  test "auto_categorize fails closed on malformed entries rather than accepting them" do
    categories = [ { name: "Groceries" } ]

    cases = {
      missing_transaction_id: [ { "category_name" => "Groceries" } ],
      missing_category_name: [ { "transaction_id" => "1" } ],
      non_scalar_transaction_id: [ { "transaction_id" => { "id" => "1" }, "category_name" => "Groceries" } ],
      blank_transaction_id: [ { "transaction_id" => "", "category_name" => "Groceries" } ],
      category_name_wrong_type: [ { "transaction_id" => "1", "category_name" => 7 } ],
      category_name_not_admitted: [ { "transaction_id" => "1", "category_name" => "Not a real category" } ],
      duplicate_transaction_ids: [
        { "transaction_id" => "1", "category_name" => "Groceries" },
        { "transaction_id" => "1", "category_name" => "null" }
      ]
    }

    cases.each do |label, entries|
      stub_ruby_llm_context(FakeChat.new(final_message: FakeMessage.new(content: { "categorizations" => entries })))
      stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")

      response = nil
      with_env_overrides OPENAI_API_KEY: "test-openai-key" do
        response = Provider::RubyLlm.new.auto_categorize(
          transactions: [ { id: "1" } ], user_categories: categories, model: "openai/gpt-5-nano"
        )
      end

      refute response.success?, "expected #{label} to fail closed"
      assert_nil response.data
      assert_kind_of Provider::RubyLlm::Error, response.error
    end
  end

  test "auto_categorize fails closed when transaction_id is an Integer instead of a String" do
    content = { "categorizations" => [ { "transaction_id" => 1, "category_name" => "Groceries" } ] }

    stub_ruby_llm_context(FakeChat.new(final_message: FakeMessage.new(content: content)))
    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")

    response = nil
    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      response = Provider::RubyLlm.new.auto_categorize(
        transactions: [ { id: "1" } ], user_categories: [ { name: "Groceries" } ], model: "openai/gpt-5-nano"
      )
    end

    refute response.success?, "expected an Integer transaction_id to fail closed"
    assert_nil response.data
    assert_kind_of Provider::RubyLlm::Error, response.error
  end

  test "auto_categorize still accepts legitimate String transaction ids and nulls" do
    content = { "categorizations" => [ { "transaction_id" => "1", "category_name" => "null" } ] }

    stub_ruby_llm_context(FakeChat.new(final_message: FakeMessage.new(content: content)))
    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")

    response = nil
    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      response = Provider::RubyLlm.new.auto_categorize(
        transactions: [ { id: "1" } ], user_categories: [ { name: "Groceries" } ], model: "openai/gpt-5-nano"
      )
    end

    assert response.success?
    assert_equal "1", response.data.first.transaction_id
    assert_nil response.data.first.category_name
  end

  test "auto_categorize canonicalizes integer input ids to strings outbound and restores the original ids in results" do
    content = { "categorizations" => [ { "transaction_id" => "42", "category_name" => "Groceries" } ] }
    chat = FakeChat.new(final_message: FakeMessage.new(content: content))
    stub_ruby_llm_context(chat)
    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")

    transactions = [ { id: 42, description: "Whole Foods" } ]
    categories = [ { name: "Groceries" } ]

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.auto_categorize(transactions: transactions, user_categories: categories, model: "openai/gpt-5-nano")
    end

    assert @response.success?

    # The domain id is restored to its original Integer type so Family integer
    # equality still matches.
    assert_equal 42, @response.data.first.transaction_id
    assert_kind_of Integer, @response.data.first.transaction_id

    # Outbound schema enum uses canonical Strings only (no mixed types).
    enum = chat.schema.dig(:schema, :properties, :categorizations, :items, :properties, :transaction_id, :enum)
    assert_equal [ "42" ], enum
    assert enum.all? { |value| value.is_a?(String) }

    # Outbound prompt carries the String id, never the Integer form.
    assert_includes chat.prompt, "\"id\":\"42\""
    refute_includes chat.prompt, "\"id\":42"

    # Caller input hashes are not mutated.
    assert_equal 42, transactions.first[:id]
    assert_equal [ { id: 42, description: "Whole Foods" } ], transactions
  end

  test "auto_categorize keeps String/UUID input ids unchanged and tolerates unknown String ids" do
    content = {
      "categorizations" => [
        { "transaction_id" => "abcd-uuid", "category_name" => "Groceries" },
        { "transaction_id" => "unknown-extra", "category_name" => "Groceries" }
      ]
    }
    chat = FakeChat.new(final_message: FakeMessage.new(content: content))
    stub_ruby_llm_context(chat)
    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")

    transactions = [ { id: "abcd-uuid", description: "Whole Foods" } ]

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.auto_categorize(transactions: transactions, user_categories: [ { name: "Groceries" } ], model: "openai/gpt-5-nano")
    end

    assert @response.success?
    assert_equal [ "abcd-uuid", "unknown-extra" ], @response.data.map(&:transaction_id)
    assert @response.data.all? { |result| result.transaction_id.is_a?(String) }

    enum = chat.schema.dig(:schema, :properties, :categorizations, :items, :properties, :transaction_id, :enum)
    assert_equal [ "abcd-uuid" ], enum
  end

  test "auto_categorize fails closed on malformed, refused, or shapeless structured output" do
    cases = {
      malformed_json: FakeMessage.new(content: "this is not json"),
      provider_refusal: FakeMessage.new(content: nil),
      missing_array: FakeMessage.new(content: { "unexpected" => [] }),
      non_array: FakeMessage.new(content: { "categorizations" => "nope" }),
      non_object_entries: FakeMessage.new(content: { "categorizations" => [ "nope" ] })
    }

    cases.each do |label, final_message|
      stub_ruby_llm_context(FakeChat.new(final_message: final_message))
      stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")

      response = nil
      with_env_overrides OPENAI_API_KEY: "test-openai-key" do
        response = Provider::RubyLlm.new.auto_categorize(
          transactions: [ { id: "1" } ], user_categories: [], model: "openai/gpt-5-nano"
        )
      end

      refute response.success?, "expected #{label} to fail closed"
      assert_nil response.data
      assert_kind_of Provider::RubyLlm::Error, response.error
    end
  end

  test "auto_categorize fails closed without touching RubyLLM when the explicit model reference is blank or unsupported" do
    RubyLLM.expects(:context).never

    [ nil, "", "opencode_go/grok-4-fast", "openai/does-not-exist", "anthropic/claude-3-5-sonnet" ].each do |reference|
      response = @provider.auto_categorize(transactions: [ { id: "1" } ], user_categories: [], model: reference)

      refute response.success?, "expected #{reference.inspect} to fail"
      assert_nil response.data
      assert_kind_of Provider::RubyLlm::Error, response.error
    end
  end

  test "auto_categorize fails closed when a catalogued model is not live-admitted" do
    RubyLLM.expects(:context).never

    stub_live_models(:openai, entries: [ model_entry("gpt-4o") ], auth_key: "test-openai-key")

    response = nil
    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      response = @provider.auto_categorize(transactions: [ { id: "1" } ], user_categories: [], model: "openai/gpt-5-nano")
    end

    refute response.success?
    assert_nil response.data
    assert_kind_of Provider::RubyLlm::Error, response.error
    assert_match(/live openai model list/, response.error.message)
  end

  test "auto_categorize fails closed when the credential is missing" do
    response = nil
    with_env_overrides OPENAI_API_KEY: nil, OPENCODE_GO_API_KEY: nil do
      response = @provider.auto_categorize(transactions: [ { id: "1" } ], user_categories: [], model: "openai/gpt-5-nano")
    end

    refute response.success?
    assert_nil response.data
    assert_kind_of Provider::RubyLlm::Error, response.error
    assert_match(/OPENAI_API_KEY/, response.error.message)
  end

  test "auto_categorize fails closed when the batch exceeds the legacy limit" do
    RubyLLM.expects(:context).never

    transactions = Array.new(Provider::RubyLlm::MAX_ENRICHMENT_TRANSACTIONS + 1) { |i| { id: i.to_s } }

    response = @provider.auto_categorize(transactions: transactions, user_categories: [], model: "openai/gpt-5-nano")

    refute response.success?
    assert_nil response.data
    assert_kind_of Provider::RubyLlm::Error, response.error
    assert_match(/Too many transactions to auto-categorize/, response.error.message)
  end

  test "auto_categorize sends the strict JSON schema over HTTP and parses the structured response through the real RubyLLM SDK" do
    chat_url = Provider::RubyLlm::OPENAI_BASE_URL + "/chat/completions"
    structured = { "categorizations" => [ { "transaction_id" => "1", "category_name" => "Groceries" } ] }

    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")

    stub_request(:post, chat_url)
      .with(headers: { "Authorization" => "Bearer test-openai-key" })
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          id: "chatcmpl-1",
          object: "chat.completion",
          created: 1,
          model: "gpt-5-nano",
          choices: [
            { index: 0, message: { role: "assistant", content: structured.to_json }, finish_reason: "stop" }
          ],
          usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
        }.to_json
      )

    transactions = [ { id: "1", description: "Whole Foods" } ]
    categories = [ { name: "Groceries" } ]

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.auto_categorize(transactions: transactions, user_categories: categories, model: "openai/gpt-5-nano")
    end

    assert @response.success?, "expected success, got: #{@response.error&.message}"
    assert_equal 1, @response.data.size
    assert_equal "1", @response.data.first.transaction_id
    assert_equal "Groceries", @response.data.first.category_name

    assert_requested(:post, chat_url) do |request|
      body = JSON.parse(request.body)
      json_schema = body.dig("response_format", "json_schema")

      json_schema["name"] == "auto_categorize" &&
        json_schema["strict"] == true &&
        json_schema["schema"]["additionalProperties"] == false &&
        json_schema["schema"]["properties"]["categorizations"]["items"]["additionalProperties"] == false &&
        json_schema["schema"]["properties"]["categorizations"]["items"]["properties"]["transaction_id"]["enum"] == [ "1" ] &&
        json_schema["schema"]["properties"]["categorizations"]["items"]["properties"]["category_name"]["enum"] == [ "Groceries", "null" ]
    end
  end

  test "auto_categorize canonicalizes integer ids over HTTP with a strict String schema and restores the original id" do
    chat_url = Provider::RubyLlm::OPENAI_BASE_URL + "/chat/completions"
    structured = { "categorizations" => [ { "transaction_id" => "42", "category_name" => "Groceries" } ] }

    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")

    stub_request(:post, chat_url)
      .with(headers: { "Authorization" => "Bearer test-openai-key" })
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          id: "chatcmpl-intcat",
          object: "chat.completion",
          created: 1,
          model: "gpt-5-nano",
          choices: [
            { index: 0, message: { role: "assistant", content: structured.to_json }, finish_reason: "stop" }
          ],
          usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 }
        }.to_json
      )

    transactions = [ { id: 42, description: "Whole Foods" } ]

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.auto_categorize(transactions: transactions, user_categories: [ { name: "Groceries" } ], model: "openai/gpt-5-nano")
    end

    assert @response.success?, "expected success, got: #{@response.error&.message}"
    assert_equal 42, @response.data.first.transaction_id
    assert_kind_of Integer, @response.data.first.transaction_id
    assert_equal "Groceries", @response.data.first.category_name

    assert_requested(:post, chat_url) do |request|
      body = JSON.parse(request.body)
      json_schema = body.dig("response_format", "json_schema")
      enum = json_schema.dig("schema", "properties", "categorizations", "items", "properties", "transaction_id", "enum")

      json_schema["strict"] == true &&
        enum == [ "42" ] &&
        enum.all? { |value| value.is_a?(String) } &&
        !request.body.match?(/"enum":\[\s*\d/)
    end
  end

  # --- bounded execution, failure categories, and safe diagnostics (#16) ----

  test "bounds per-call execution with a local timeout and one non-streaming retry for both accounts" do
    # OpenAI streaming chat: the adapter must cap the local context timeout at
    # well under RubyLLM's 300s default and must disable retries entirely.
    streaming_chat = FakeChat.new(final_message: FakeMessage.new(content: "Hi", id: "msg_bounds"))
    streaming_config, streaming_context = stub_ruby_llm_context(streaming_chat)

    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @provider.chat_response("Hello", model: "openai/gpt-5-nano", streamer: proc { })
    end

    assert_equal({ model: "gpt-5-nano", provider: :openai, protocol: :chat_completions, assume_model_exists: true }, streaming_context.chat_options)

    assert_equal 120, streaming_config.request_timeout
    assert_equal 0, streaming_config.max_retries
    assert_equal 0.5, streaming_config.retry_interval
    assert_equal 2, streaming_config.retry_max_interval
    assert_equal 2, streaming_config.retry_backoff_factor
    assert_equal 0.5, streaming_config.retry_interval_randomness
    assert_equal Provider::RubyLlm::StreamingAdapter, streaming_config.faraday_adapter

    # OpenAI structured ask (non-streaming): identical timeout bounds with
    # exactly one bounded retry instead of RubyLLM's default of three.
    structured_chat = FakeChat.new(final_message: FakeMessage.new(
      content: { "categorizations" => [ { "transaction_id" => "1", "category_name" => "Groceries" } ] }
    ))
    structured_config, structured_context = stub_ruby_llm_context(structured_chat)

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @provider.auto_categorize(transactions: [ { id: "1" } ], user_categories: [ { name: "Groceries" } ], model: "openai/gpt-5-nano")
    end

    assert_equal({ model: "gpt-5-nano", provider: :openai, protocol: :chat_completions, assume_model_exists: true }, structured_context.chat_options)

    assert_equal 120, structured_config.request_timeout
    assert_equal 1, structured_config.max_retries
    assert_equal 0.5, structured_config.retry_interval
    assert_equal 2, structured_config.retry_max_interval
    assert_equal 2, structured_config.retry_backoff_factor
    assert_equal 0.5, structured_config.retry_interval_randomness
    assert_equal Provider::RubyLlm::StreamingAdapter, structured_config.faraday_adapter

    # OpenCode Go structured ask: the same bounds apply to the second account,
    # and account isolation (key/base) still holds inside the shared bounds.
    go_chat = FakeChat.new(final_message: FakeMessage.new(
      content: { "categorizations" => [ { "transaction_id" => "1", "category_name" => "Groceries" } ] }
    ))
    go_config, go_context = stub_ruby_llm_context(go_chat)

    stub_live_models(:opencode_go, entries: [ model_entry("glm-5.3-flash") ], auth_key: "test-go-key")

    with_env_overrides OPENCODE_GO_API_KEY: "test-go-key" do
      @provider.auto_categorize(transactions: [ { id: "1" } ], user_categories: [ { name: "Groceries" } ], model: "opencode_go/glm-5.3-flash")
    end

    assert_equal({ model: "glm-5.3-flash", provider: :openai, protocol: :chat_completions, assume_model_exists: true }, go_context.chat_options)

    assert_equal "test-go-key", go_config.openai_api_key
    assert_equal Provider::RubyLlm::OPENCODE_GO_BASE_URL, go_config.openai_api_base
    assert_equal 120, go_config.request_timeout
    assert_equal 1, go_config.max_retries
    assert_equal 0.5, go_config.retry_interval
    assert_equal 2, go_config.retry_max_interval
    assert_equal 2, go_config.retry_backoff_factor
    assert_equal 0.5, go_config.retry_interval_randomness
    assert_equal Provider::RubyLlm::StreamingAdapter, go_config.faraday_adapter

    # The bounds are adapter-local: the global RubyLLM config keeps the gem
    # defaults and Kuria adds no global initializer for them.
    assert_equal 300, RubyLLM.config.request_timeout
    assert_equal 3, RubyLLM.config.max_retries
    assert_equal 30, RubyLLM.config.retry_max_interval
    assert_nil RubyLLM.config.openai_api_key

    # The timeout is the per-operation read timeout, not a total wall-clock
    # deadline, and the structured retry interval cap is explicit and finite.
    assert_equal Provider::RubyLlm::RETRY_MAX_INTERVAL_SECONDS, 2
  end

  test "maps the full failure category set to the safe error envelope with sanitized messages" do
    cases = {
      authentication: [ RubyLLM::UnauthorizedError, "Incorrect API key provided: sk-test-secret-123", false, /authentication failed/ ],
      rate_limit: [ RubyLLM::RateLimitError, "Rate limit exceeded for sk-test-secret-123", true, /rate limit/i ],
      server_error: [ RubyLLM::ServerError, "internal backend error", true, /API error/ ],
      service_unavailable: [ RubyLLM::ServiceUnavailableError, "service unavailable", true, /API error/ ],
      overloaded: [ RubyLLM::OverloadedError, "provider overloaded", true, /API error/ ],
      context_length: [ RubyLLM::ContextLengthExceededError, "This model supports at most 8192 tokens", false, /context length/i ],
      unknown_model: [ RubyLLM::ModelNotFoundError, "Model 'made-up-model' does not exist", false, /could not resolve model/ ],
      configuration: [ RubyLLM::ConfigurationError, "No API key configured for openai", false, /configuration error/i ],
      timeout: [ Faraday::TimeoutError, nil, true, /connection error/ ],
      connection: [ Faraday::ConnectionFailed, nil, true, /connection error/ ]
    }

    cases.each do |label, (error_class, error_message, retryable, message_pattern)|
      chat = FakeChat.new(final_message: nil)
      if error_message
        chat.stubs(:ask).raises(error_class, error_message)
      else
        chat.stubs(:ask).raises(error_class)
      end
      stub_ruby_llm_context(chat)

      stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")

      with_env_overrides OPENAI_API_KEY: "test-openai-key" do
        @response = @provider.chat_response("What is my net worth?", model: "openai/gpt-5-nano")
      end

      refute @response.success?, "expected #{label} to return the failure envelope"
      assert_nil @response.data, "expected #{label} to carry no data"
      error = @response.error
      assert_kind_of Provider::RubyLlm::Error, error, "expected #{label} to map into the provider error envelope"
      assert_match message_pattern, error.message, "expected #{label} to carry the safe category message"

      assert_equal "openai", error.details[:provider_reference], "#{label} metadata must name the provider"
      assert_equal "openai/gpt-5-nano", error.details[:model], "#{label} metadata must name the model"
      assert_equal error_class.name, error.details[:error_class], "#{label} metadata must name the error class"
      assert_equal retryable, error.details[:retryable], "#{label} retryability must be explicit"

      # No credentials, no provider error text, no user prompt, and no RubyLLM
      # raw exception message ever escapes into the user-facing envelope.
      refute_match(/sk-test-secret-123/, error.message)
      refute_match(/What is my net worth/, error.message)
    end
  end

  test "error metadata distinguishes OpenCode Go failures from OpenAI" do
    chat = FakeChat.new(final_message: nil)
    chat.stubs(:ask).raises(RubyLLM::RateLimitError, "Rate limit exceeded")
    stub_ruby_llm_context(chat)

    stub_live_models(:opencode_go, entries: [ model_entry("glm-5.3-flash") ], auth_key: "test-go-key")

    with_env_overrides OPENCODE_GO_API_KEY: "test-go-key" do
      @response = @provider.chat_response("Hello", model: "opencode_go/glm-5.3-flash")
    end

    refute @response.success?
    error = @response.error
    assert_kind_of Provider::RubyLlm::Error, error
    assert_equal "opencode_go", error.details[:provider_reference]
    assert_equal "opencode_go/glm-5.3-flash", error.details[:model]
    assert_equal "RubyLLM::RateLimitError", error.details[:error_class]
    assert_equal true, error.details[:retryable]
    assert_match(/opencode_go/, error.message)
    refute_match(/test-go-key/, error.message)
  end

  test "non-streaming retry exhaustion surfaces the rate-limit envelope after exactly one bounded retry" do
    chat_url = Provider::RubyLlm::OPENAI_BASE_URL + "/chat/completions"

    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")

    stub_request(:post, chat_url)
      .with(headers: { "Authorization" => "Bearer test-openai-key" })
      .to_return(
        status: 429,
        headers: { "Content-Type" => "application/json" },
        body: { "error" => { "message" => "SECRET-RIPE-INTERNAL-DETAIL", "type" => "rate_limit_error" } }.to_json
      )

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.auto_categorize(
        transactions: [ { id: "1" } ], user_categories: [ { name: "Groceries" } ], model: "openai/gpt-5-nano"
      )
    end

    refute @response.success?
    assert_nil @response.data
    assert_kind_of Provider::RubyLlm::Error, @response.error
    assert_equal "RubyLLM::RateLimitError", @response.error.details[:error_class]
    assert_equal true, @response.error.details[:retryable]
    # Bounded execution: the initial request plus exactly one retry — the gem's
    # default max_retries of 3 would have produced four requests.
    assert_requested :post, chat_url, times: 2
    # The provider body (and its raw details) never surface in the envelope.
    refute_match(/SECRET-RIPE-INTERNAL-DETAIL/, @response.error.message)
  end

  test "a failed streaming chat is never retried, delivers no duplicate chunks, and stops through the envelope" do
    chat_url = Provider::RubyLlm::OPENAI_BASE_URL + "/chat/completions"

    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")

    stub_request(:post, chat_url)
      .with(headers: { "Authorization" => "Bearer test-openai-key" })
      .to_return(status: 500, headers: { "Content-Type" => "application/json" }, body: { "error" => { "message" => "boom" } }.to_json)

    collected = []
    streamer = proc { |chunk| collected << chunk }

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.chat_response("What is my net worth?", model: "openai/gpt-5-nano", streamer: streamer)
    end

    refute @response.success?
    # No retried request may replay the partially streamed answer: the failed
    # streaming chat attempts exactly one POST.
    assert_requested :post, chat_url, times: 1
    assert_equal [], collected, "failed streaming chats must not stream chunks or a completed response"
    assert_kind_of Provider::RubyLlm::Error, @response.error
    # RubyLLM 2.1.1 classifies a streamed 500 through the same status mapping as
    # a buffered response, so this is a retryable server error (the 1.16
    # streaming path mislabeled it BadRequestError).
    assert_equal "RubyLLM::ServerError", @response.error.details[:error_class]
    assert_equal true, @response.error.details[:retryable]
    refute_match(/What is my net worth/, @response.error.message)
  end

  # --- strict Chat Completions streaming (#16 finding 4) -------------------

  test "streams a valid chat completions SSE response once with usage and no duplicate chunks" do
    body = [
      sse_comment("keep-alive"),
      sse_event(stream_chunk(role: "assistant")),
      sse_event(stream_chunk(content: "Hello ")),
      sse_event(stream_chunk(content: "world")),
      sse_event(usage_chunk),
      sse_event(stream_chunk(finish_reason: "stop")),
      sse_event("[DONE]")
    ].join

    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")
    stub_stream(OPENAI_CHAT_URL, body, token: "test-openai-key")

    collected = []
    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.chat_response("Hello", model: "openai/gpt-5-nano", streamer: proc { |chunk| collected << chunk })
    end

    assert @response.success?, "expected success, got: #{@response.error&.message}"
    assert_equal "Hello world", @response.data.messages.first.output_text
    assert_equal [ "Hello ", "world" ], collected.select { |chunk| chunk.type == "output_text" }.map(&:data)
    assert_equal 1, collected.count { |chunk| chunk.type == "response" }
    assert_requested :post, OPENAI_CHAT_URL, times: 1
  end

  test "streams OpenCode Go over the pinned chat completions protocol with one POST" do
    body = [
      sse_event(stream_chunk(content: "Go answer")),
      sse_event(stream_chunk(finish_reason: "stop")),
      sse_event("[DONE]")
    ].join

    stub_live_models(:opencode_go, entries: [ model_entry("glm-5.3-flash") ], auth_key: "test-go-key")
    stub_stream(OPENCODE_GO_CHAT_URL, body, token: "test-go-key")

    with_env_overrides OPENCODE_GO_API_KEY: "test-go-key" do
      @response = @provider.chat_response("Hello", model: "opencode_go/glm-5.3-flash")
    end

    assert @response.success?, "expected success, got: #{@response.error&.message}"
    assert_equal "Go answer", @response.data.messages.first.output_text
    assert_requested :post, OPENCODE_GO_CHAT_URL, times: 1
  end

  test "rejects malformed SSE JSON through the provider envelope without retrying" do
    body = [
      sse_event(stream_chunk(content: "Hello")),
      "data: {\"choices\":[SECRET-BROKEN]\n\n",
      sse_event("[DONE]")
    ].join

    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")
    stub_stream(OPENAI_CHAT_URL, body, token: "test-openai-key")

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.chat_response("Hello", model: "openai/gpt-5-nano", streamer: proc { })
    end

    refute @response.success?
    assert_nil @response.data
    error = @response.error
    assert_kind_of Provider::RubyLlm::Error, error
    assert_match(/stream was malformed or incomplete/i, error.message)
    assert_equal "Provider::RubyLlm::StreamingAdapter::InvalidStreamError", error.details[:error_class]
    assert_equal true, error.details[:retryable]
    assert_equal "openai", error.details[:provider_reference]
    assert_equal "openai/gpt-5-nano", error.details[:model]
    refute_match(/SECRET-BROKEN/, error.message)
    assert_requested :post, OPENAI_CHAT_URL, times: 1
  end

  test "rejects a truncated SSE stream that never sends DONE" do
    body = [
      sse_event(stream_chunk(content: "Partial")),
      sse_event(stream_chunk(finish_reason: "stop"))
    ].join

    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")
    stub_stream(OPENAI_CHAT_URL, body, token: "test-openai-key")

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.chat_response("Hello", model: "openai/gpt-5-nano", streamer: proc { })
    end

    refute @response.success?
    assert_kind_of Provider::RubyLlm::Error, @response.error
    assert_match(/stream was malformed or incomplete/i, @response.error.message)
    assert_equal true, @response.error.details[:retryable]
    assert_requested :post, OPENAI_CHAT_URL, times: 1
  end

  test "rejects a malformed SSE event after finish_reason stop even when DONE follows" do
    body = [
      sse_event(stream_chunk(content: "Done")),
      sse_event(stream_chunk(finish_reason: "stop")),
      "data: {not-json\n\n",
      sse_event("[DONE]")
    ].join

    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")
    stub_stream(OPENAI_CHAT_URL, body, token: "test-openai-key")

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.chat_response("Hello", model: "openai/gpt-5-nano", streamer: proc { })
    end

    refute @response.success?
    assert_kind_of Provider::RubyLlm::Error, @response.error
    assert_match(/stream was malformed or incomplete/i, @response.error.message)
    assert_equal "Provider::RubyLlm::StreamingAdapter::InvalidStreamError", @response.error.details[:error_class]
    assert_requested :post, OPENAI_CHAT_URL, times: 1
  end

  test "rejects a buffered JSON completion on a streaming request" do
    body = {
      id: "chatcmpl-buffered",
      object: "chat.completion",
      model: "gpt-5-nano",
      choices: [ { index: 0, message: { role: "assistant", content: "buffered" }, finish_reason: "stop" } ]
    }.to_json

    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")
    stub_request(:post, OPENAI_CHAT_URL)
      .with(headers: { "Authorization" => "Bearer test-openai-key" })
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: body)

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.chat_response("Hello", model: "openai/gpt-5-nano", streamer: proc { })
    end

    refute @response.success?
    assert_kind_of Provider::RubyLlm::Error, @response.error
    assert_match(/stream was malformed or incomplete/i, @response.error.message)
    assert_equal "Provider::RubyLlm::StreamingAdapter::InvalidStreamError", @response.error.details[:error_class]
  end

  test "rejects a usage-only SSE stream that never produces a completion" do
    body = [ sse_event(usage_chunk), sse_event("[DONE]") ].join

    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")
    stub_stream(OPENAI_CHAT_URL, body, token: "test-openai-key")

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.chat_response("Hello", model: "openai/gpt-5-nano", streamer: proc { })
    end

    refute @response.success?
    assert_kind_of Provider::RubyLlm::Error, @response.error
    assert_match(/stream was malformed or incomplete/i, @response.error.message)
    assert_equal true, @response.error.details[:retryable]
  end

  test "passes provider error events to RubyLLM's normal classifier" do
    body = [
      sse_error_event({ error: { message: "SECRET-EVENT-DETAIL", type: "server_error" } }),
      sse_event("[DONE]")
    ].join

    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")
    stub_stream(OPENAI_CHAT_URL, body, token: "test-openai-key")

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.chat_response("Hello", model: "openai/gpt-5-nano", streamer: proc { })
    end

    refute @response.success?
    assert_kind_of Provider::RubyLlm::Error, @response.error
    assert_equal "RubyLLM::ServerError", @response.error.details[:error_class]
    assert_equal true, @response.error.details[:retryable]
    refute_match(/SECRET-EVENT-DETAIL/, @response.error.message)
    refute_match(/malformed or incomplete/i, @response.error.message)
  end

  test "classifies streaming HTTP failures for both accounts with correct retryability and one POST" do
    accounts = {
      openai: [ OPENAI_CHAT_URL, "OPENAI_API_KEY", "test-openai-key", "openai/gpt-5-nano", "gpt-5-nano" ],
      opencode_go: [ OPENCODE_GO_CHAT_URL, "OPENCODE_GO_API_KEY", "test-go-key", "opencode_go/glm-5.3-flash", "glm-5.3-flash" ]
    }
    cases = {
      401 => [ "RubyLLM::UnauthorizedError", false ],
      429 => [ "RubyLLM::RateLimitError", true ],
      500 => [ "RubyLLM::ServerError", true ]
    }

    accounts.each do |account, (chat_url, credential, token, reference, model_id)|
      cases.each do |status, (error_class, retryable)|
        WebMock.reset!
        stub_live_models(account, entries: [ model_entry(model_id) ], auth_key: token)
        stub_request(:post, chat_url)
          .with(headers: { "Authorization" => "Bearer #{token}" })
          .to_return(
            status: status,
            headers: { "Content-Type" => "application/json" },
            body: { "error" => { "message" => "SECRET-STREAM-BODY" } }.to_json
          )

        response = nil
        with_env_overrides(credential => token) do
          response = Provider::RubyLlm.new.chat_response("Hello", model: reference, streamer: proc { })
        end

        refute response.success?, "expected #{account} #{status} to fail closed"
        assert_nil response.data
        assert_kind_of Provider::RubyLlm::Error, response.error
        assert_equal error_class, response.error.details[:error_class], "#{account} #{status}"
        assert_equal retryable, response.error.details[:retryable], "#{account} #{status}"
        assert_equal account.to_s, response.error.details[:provider_reference]
        assert_equal reference, response.error.details[:model]
        refute_match(/SECRET-STREAM-BODY/, response.error.message)
        assert_requested :post, chat_url, times: 1
      end
    end
  end

  test "validates SSE split across adapter callbacks with request-local state" do
    adapter = Provider::RubyLlm::StreamingAdapter.new
    chunks = [
      "data: {\"choices\":[{\"delta\":{\"cont",
      "ent\":\"Hi\"}}]}\n\n",
      "data: [DONE]\n\n"
    ]
    received = []
    env = stream_env(received)

    streams = [
      chunks,
      [ "data: {\"choices\":[{\"delta\":{\"content\":\"Truncated\"}}]}\n\n" ]
    ]
    adapter.define_singleton_method(:perform_request) do |_http, callback_env|
      streams.shift.each { |chunk| callback_env.request.on_data.call(chunk, 0, callback_env) }
      true
    end

    adapter.call(env)
    assert_equal chunks, received

    # The same shared adapter instance must not carry the first request's
    # parser/DONE state into a second, truncated request.
    assert_raises(Provider::RubyLlm::StreamingAdapter::InvalidStreamError) do
      adapter.call(stream_env([]))
    end
  end

  test "permits comments, usage-only chunks, and tool-call chunks" do
    adapter = Provider::RubyLlm::StreamingAdapter.new
    chunks = [
      sse_comment("keep-alive"),
      sse_event(stream_chunk(tool_calls: [
        { "index" => 0, "id" => "call_1", "type" => "function", "function" => { "name" => "lookup", "arguments" => "{}" } }
      ])),
      sse_event(usage_chunk),
      sse_event("[DONE]")
    ]
    received = []

    adapter.define_singleton_method(:perform_request) do |_http, callback_env|
      chunks.each { |chunk| callback_env.request.on_data.call(chunk, 0, callback_env) }
      true
    end

    adapter.call(stream_env(received))
    assert_equal chunks, received
  end

  # --- malformed/empty provider error events --------------------------------

  test "rejects a malformed provider error event instead of completing" do
    body = [
      sse_event(stream_chunk(content: "Partial")),
      "event: error\ndata: {NOT-JSON\n\n",
      sse_event("[DONE]")
    ].join

    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")
    stub_stream(OPENAI_CHAT_URL, body, token: "test-openai-key")

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.chat_response("Hello", model: "openai/gpt-5-nano", streamer: proc { })
    end

    refute @response.success?
    assert_kind_of Provider::RubyLlm::Error, @response.error
    assert_match(/stream was malformed or incomplete/i, @response.error.message)
    assert_equal "Provider::RubyLlm::StreamingAdapter::InvalidStreamError", @response.error.details[:error_class]
    assert_equal true, @response.error.details[:retryable]
    refute_match(/NOT-JSON/, @response.error.message)
    assert_requested :post, OPENAI_CHAT_URL, times: 1
  end

  # Approved relaxation: an empty SSE event carries no data, so the SDK does
  # not dispatch it and it must not fail an otherwise complete stream.
  test "ignores empty SSE events the SDK does not dispatch" do
    body = [
      sse_event(stream_chunk(content: "Partial")),
      "event: error\n\n",
      sse_event("[DONE]")
    ].join

    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")
    stub_stream(OPENAI_CHAT_URL, body, token: "test-openai-key")

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.chat_response("Hello", model: "openai/gpt-5-nano", streamer: proc { })
    end

    assert @response.success?, "expected success, got: #{@response.error&.message}"
    assert_equal "Partial", @response.data.messages.first.output_text
    assert_requested :post, OPENAI_CHAT_URL, times: 1
  end

  # A dispatched error event, even with empty data, must still fail closed.
  test "rejects an empty provider error event instead of completing" do
    [
      "event: error\ndata: \n\n",
      "event: error\ndata: {}\n\n"
    ].each do |error_event|
      WebMock.reset!
      body = [ sse_event(stream_chunk(content: "Partial")), error_event, sse_event("[DONE]") ].join

      stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")
      stub_stream(OPENAI_CHAT_URL, body, token: "test-openai-key")

      response = nil
      with_env_overrides OPENAI_API_KEY: "test-openai-key" do
        response = Provider::RubyLlm.new.chat_response("Hello", model: "openai/gpt-5-nano", streamer: proc { })
      end

      refute response.success?, "expected #{error_event.inspect} to fail closed"
      assert_kind_of Provider::RubyLlm::Error, response.error
      assert_match(/stream was malformed or incomplete/i, response.error.message)
      assert_equal "Provider::RubyLlm::StreamingAdapter::InvalidStreamError", response.error.details[:error_class]
      assert_requested :post, OPENAI_CHAT_URL, times: 1
    end
  end

  # --- terminal ordering ----------------------------------------------------

  test "rejects a complete event after DONE instead of appending it" do
    body = [
      sse_event(stream_chunk(content: "Before")),
      sse_event("[DONE]"),
      sse_event(stream_chunk(content: "After"))
    ].join

    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")
    stub_stream(OPENAI_CHAT_URL, body, token: "test-openai-key")

    collected = []
    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.chat_response("Hello", model: "openai/gpt-5-nano", streamer: proc { |chunk| collected << chunk })
    end

    refute @response.success?
    refute_match(/BeforeAfter/, @response.data.to_s)
    assert_kind_of Provider::RubyLlm::Error, @response.error
    assert_match(/stream was malformed or incomplete/i, @response.error.message)
    assert_equal "Provider::RubyLlm::StreamingAdapter::InvalidStreamError", @response.error.details[:error_class]
    refute_includes collected.select { |chunk| chunk.type == "output_text" }.map(&:data), "After"
  end

  test "rejects a post-terminal event when DONE and the event arrive in separate callbacks" do
    adapter = Provider::RubyLlm::StreamingAdapter.new
    streams = [
      [
        sse_event(stream_chunk(content: "Before")),
        "data: [DONE]\n",
        "\n",
        sse_event(stream_chunk(content: "After"))
      ]
    ]
    adapter.define_singleton_method(:perform_request) do |_http, callback_env|
      streams.shift.each { |chunk| callback_env.request.on_data.call(chunk, 0, callback_env) }
      true
    end

    assert_raises(Provider::RubyLlm::StreamingAdapter::InvalidStreamError) do
      adapter.call(stream_env([]))
    end
  end

  # Approved relaxation: after a complete DONE, unfinished trailing bytes the
  # SDK never dispatches are ignored instead of rejected. A dispatched event
  # after DONE is still rejected (see the terminal-ordering tests above).
  test "ignores unfinished bytes after DONE at EOF" do
    adapter = Provider::RubyLlm::StreamingAdapter.new
    chunks = [
      sse_event(stream_chunk(content: "Before")),
      "data: [DONE]\n\n",
      "data: {BAD"
    ]
    received = []
    adapter.define_singleton_method(:perform_request) do |_http, callback_env|
      chunks.each { |chunk| callback_env.request.on_data.call(chunk, 0, callback_env) }
      true
    end

    adapter.call(stream_env(received))
    assert_equal chunks, received
  end

  test "allows comments and whitespace after DONE" do
    body = [
      sse_event(stream_chunk(content: "Before")),
      sse_event("[DONE]"),
      sse_comment("keep-alive after done"),
      "   \n\n"
    ].join

    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")
    stub_stream(OPENAI_CHAT_URL, body, token: "test-openai-key")

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.chat_response("Hello", model: "openai/gpt-5-nano", streamer: proc { })
    end

    assert @response.success?, "expected success, got: #{@response.error&.message}"
    assert_equal "Before", @response.data.messages.first.output_text
  end

  test "accepts the DONE marker split across transport callbacks" do
    adapter = Provider::RubyLlm::StreamingAdapter.new
    chunks = [
      sse_event(stream_chunk(content: "Hi")),
      "data: [DO",
      "NE]\n\n"
    ]
    received = []
    adapter.define_singleton_method(:perform_request) do |_http, callback_env|
      chunks.each { |chunk| callback_env.request.on_data.call(chunk, 0, callback_env) }
      true
    end

    adapter.call(stream_env(received))
    assert_equal chunks, received
  end

  test "accepts CR-only line endings at EOF" do
    adapter = Provider::RubyLlm::StreamingAdapter.new
    chunks = [
      "data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}\r\r",
      "data: [DONE]\r",
      "\r"
    ]
    received = []
    adapter.define_singleton_method(:perform_request) do |_http, callback_env|
      chunks.each { |chunk| callback_env.request.on_data.call(chunk, 0, callback_env) }
      true
    end

    adapter.call(stream_env(received))
    assert_equal chunks, received
  end

  test "accepts CRLF line endings split across transport callbacks" do
    adapter = Provider::RubyLlm::StreamingAdapter.new
    chunks = [
      "data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}\r",
      "\n\r\n",
      "data: [DONE]\r",
      "\n\r\n"
    ]
    received = []
    adapter.define_singleton_method(:perform_request) do |_http, callback_env|
      chunks.each { |chunk| callback_env.request.on_data.call(chunk, 0, callback_env) }
      true
    end

    adapter.call(stream_env(received))
    assert_equal chunks, received
  end

  # --- boolean/typed chunk shape guards -------------------------------------

  test "rejects boolean-shaped chunk fields for both accounts" do
    bad_chunks = {
      delta_false: { "choices" => [ { "index" => 0, "delta" => false } ] },
      message_false: { "choices" => [ { "index" => 0, "delta" => nil, "message" => false } ] },
      usage_false: {
        "choices" => [ { "index" => 0, "delta" => { "content" => "more" } } ],
        "usage" => false
      },
      tool_calls_false: { "choices" => [ { "index" => 0, "delta" => { "tool_calls" => false } } ] },
      content_false: { "choices" => [ { "index" => 0, "delta" => { "content" => false } } ] },
      refusal_false: { "choices" => [ { "index" => 0, "delta" => { "refusal" => false } } ] },
      finish_reason_false: { "choices" => [ { "index" => 0, "delta" => {}, "finish_reason" => false } ] }
    }
    accounts = {
      openai: [ OPENAI_CHAT_URL, "OPENAI_API_KEY", "test-openai-key", "openai/gpt-5-nano", "gpt-5-nano" ],
      opencode_go: [ OPENCODE_GO_CHAT_URL, "OPENCODE_GO_API_KEY", "test-go-key", "opencode_go/glm-5.3-flash", "glm-5.3-flash" ]
    }

    accounts.each do |account, (chat_url, credential, token, reference, model_id)|
      bad_chunks.each do |label, bad_chunk|
        WebMock.reset!
        body = [
          sse_event(stream_chunk(content: "Partial")),
          sse_event(bad_chunk),
          sse_event(stream_chunk(finish_reason: "stop")),
          sse_event("[DONE]")
        ].join

        stub_live_models(account, entries: [ model_entry(model_id) ], auth_key: token)
        stub_stream(chat_url, body, token: token)

        response = nil
        with_env_overrides(credential => token) do
          response = Provider::RubyLlm.new.chat_response("Hello", model: reference, streamer: proc { })
        end

        refute response.success?, "expected #{account} #{label} to fail closed"
        assert_kind_of Provider::RubyLlm::Error, response.error
        assert_match(/stream was malformed or incomplete/i, response.error.message)
        assert_equal "Provider::RubyLlm::StreamingAdapter::InvalidStreamError", response.error.details[:error_class], "#{account} #{label}"
        assert_requested :post, chat_url, times: 1
      end
    end
  end
end
