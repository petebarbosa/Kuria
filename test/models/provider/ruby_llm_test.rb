require "test_helper"

class Provider::RubyLlmTest < ActiveSupport::TestCase
  include ProviderTestHelper

  # Deterministic stand-ins for the RubyLLM gem boundary. The adapter must
  # never leak RubyLLM objects, so these fakes only exercise the seam the
  # adapter is allowed to touch (RubyLLM.context / context.chat / chat.ask).
  class FakeConfig
    attr_reader :openai_api_key, :openai_api_base

    def openai_api_key=(value)
      @openai_api_key = value
    end

    def openai_api_base=(value)
      @openai_api_base = value
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
    attr_reader :prompt, :instructions

    def initialize(final_message:, chunks: [])
      @final_message = final_message
      @chunks = chunks
    end

    def with_instructions(instructions)
      @instructions = instructions
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

  setup do
    @provider = Provider::RubyLlm.new
  end

  def stub_ruby_llm_context(chat, config: FakeConfig.new)
    context = FakeContext.new(chat)
    RubyLLM.stubs(:context).yields(config).returns(context)
    [ config, context ]
  end

  test "supports only the canonical openai and opencode_go references" do
    assert @provider.supports_model?("openai/gpt-4o")
    assert @provider.supports_model?("opencode_go/grok-4-fast")
    refute @provider.supports_model?("opencode/big-pickle")
    refute @provider.supports_model?("anthropic/claude-3-5-sonnet")
    refute @provider.supports_model?("gpt-4o")
    refute @provider.supports_model?(nil)
  end

  test "normalizes a successful openai chat response through the provider contract" do
    final_message = FakeMessage.new(content: "Your net worth is $50,000.", id: "msg_1")
    chat = FakeChat.new(final_message: final_message)
    config, context = stub_ruby_llm_context(chat)

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.chat_response("What is my net worth?", model: "openai/gpt-4o")
    end

    assert @response.success?
    assert_nil @response.error

    data = @response.data
    assert_instance_of Provider::LlmConcept::ChatResponse, data
    assert_equal "msg_1", data.id
    assert_equal "openai/gpt-4o", data.model
    assert_equal 1, data.messages.size
    assert_instance_of Provider::LlmConcept::ChatMessage, data.messages.first
    assert_equal "Your net worth is $50,000.", data.messages.first.output_text
    assert_equal [], data.function_requests

    # Isolated per-call config: normal OpenAI base and key from OPENAI_API_KEY.
    assert_equal "test-openai-key", config.openai_api_key
    assert_equal Provider::RubyLlm::OPENAI_BASE_URL, config.openai_api_base

    # Openai references resolve through the normal registry (no assume_model_exists).
    assert_equal({ model: "gpt-4o", provider: :openai, assume_model_exists: false }, context.chat_options)

    assert_equal "What is my net worth?", chat.prompt
    assert_nil chat.instructions
  end

  test "configures the OpenCode Go endpoint, key, and model admission for opencode_go references" do
    final_message = FakeMessage.new(content: "Hello from Go.")
    chat = FakeChat.new(final_message: final_message)
    config, context = stub_ruby_llm_context(chat)

    with_env_overrides OPENCODE_GO_API_KEY: "test-go-key" do
      @response = @provider.chat_response("Hello", model: "opencode_go/grok-4-fast")
    end

    assert @response.success?
    assert_equal "test-go-key", config.openai_api_key
    assert_equal Provider::RubyLlm::OPENCODE_GO_BASE_URL, config.openai_api_base
    assert_equal({ model: "grok-4-fast", provider: :openai, assume_model_exists: true }, context.chat_options)
    assert_equal "opencode_go/grok-4-fast", @response.data.model
    assert @response.data.id.present?
  end

  test "forwards instructions to the RubyLLM chat as system instructions" do
    final_message = FakeMessage.new(content: "Sure.", id: "msg_2")
    chat = FakeChat.new(final_message: final_message)
    stub_ruby_llm_context(chat)

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.chat_response("Hello", model: "openai/gpt-4o", instructions: "You are a helpful assistant.")
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

    collected = []
    streamer = proc { |chunk| collected << chunk }

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.chat_response("Hello", model: "openai/gpt-4o", streamer: streamer)
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

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @first = @provider.chat_response("Hello", model: "openai/gpt-4o")
      @second = @provider.chat_response("Hello", model: "openai/gpt-4o")
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
      @response = @provider.chat_response("Hello", model: "openai/gpt-4o")
    end

    refute @response.success?
    assert_kind_of Provider::RubyLlm::Error, @response.error
    assert_match(/OPENAI_API_KEY/, @response.error.message)
    assert_equal "openai/gpt-4o", @response.error.details[:model]

    with_env_overrides OPENAI_API_KEY: nil, OPENCODE_GO_API_KEY: nil do
      @response = @provider.chat_response("Hello", model: "opencode_go/grok-4-fast")
    end

    refute @response.success?
    assert_match(/OPENCODE_GO_API_KEY/, @response.error.message)
    assert_equal "opencode_go/grok-4-fast", @response.error.details[:model]
  end

  test "maps RubyLLM API errors to a safe provider error without key or prompt leakage" do
    chat = FakeChat.new(final_message: nil)
    chat.stubs(:ask).raises(RubyLLM::UnauthorizedError, "Incorrect API key provided: sk-test-secret-123")
    stub_ruby_llm_context(chat)

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.chat_response("What is my net worth?", model: "openai/gpt-4o")
    end

    refute @response.success?
    assert_nil @response.data
    assert_kind_of Provider::RubyLlm::Error, @response.error
    assert_equal "openai", @response.error.details[:provider_reference]
    assert_equal "openai/gpt-4o", @response.error.details[:model]
    assert_equal "RubyLLM::UnauthorizedError", @response.error.details[:error_class]
    assert_equal false, @response.error.details[:retryable]
    refute_match(/sk-test-secret-123/, @response.error.message)
    refute_match(/What is my net worth/, @response.error.message)
  end

  test "marks rate limit and connection failures as retryable in the error details" do
    chat = FakeChat.new(final_message: nil)
    chat.stubs(:ask).raises(RubyLLM::RateLimitError, "Rate limit exceeded")
    stub_ruby_llm_context(chat)

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.chat_response("Hello", model: "openai/gpt-4o")
    end

    refute @response.success?
    assert_equal "RubyLLM::RateLimitError", @response.error.details[:error_class]
    assert_equal true, @response.error.details[:retryable]
  end

  test "maps model-not-found errors into the provider error envelope" do
    chat = FakeChat.new(final_message: nil)
    chat.stubs(:ask).raises(RubyLLM::ModelNotFoundError, "Unknown model: 'nope'")
    stub_ruby_llm_context(chat)

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @response = @provider.chat_response("Hello", model: "openai/does-not-exist")
    end

    refute @response.success?
    assert_kind_of Provider::RubyLlm::Error, @response.error
    assert_equal "RubyLLM::ModelNotFoundError", @response.error.details[:error_class]
    assert_equal false, @response.error.details[:retryable]
    assert_match(/model/, @response.error.message)
  end

  test "registry keeps OpenCode as the default when the switch is unset" do
    with_env_overrides KURIA_LLM_PROVIDER: nil do
      provider_classes = Provider::Registry.for_concept(:llm).providers.map(&:class)
      assert_includes provider_classes, Provider::Opencode
      refute_includes provider_classes, Provider::RubyLlm
    end
  end

  test "registry keeps OpenCode for an explicit opencode switch value" do
    with_env_overrides KURIA_LLM_PROVIDER: "opencode" do
      provider_classes = Provider::Registry.for_concept(:llm).providers.map(&:class)
      assert_includes provider_classes, Provider::Opencode
      refute_includes provider_classes, Provider::RubyLlm
    end
  end

  test "registry opts into the RubyLLM provider when the switch is set to ruby_llm" do
    with_env_overrides KURIA_LLM_PROVIDER: "ruby_llm" do
      provider_classes = Provider::Registry.for_concept(:llm).providers.map(&:class)
      assert_equal [ Provider::RubyLlm ], provider_classes
      assert_instance_of Provider::RubyLlm, Provider::Registry.get_provider(:ruby_llm)
    end
  end

  test "registry fails clearly for unknown switch values" do
    with_env_overrides KURIA_LLM_PROVIDER: "banana" do
      assert_raises(Provider::Registry::Error) do
        Provider::Registry.for_concept(:llm).providers
      end
    end
  end

  test "registry resolves for_concept(:llm).providers through the class-private switch helper" do
    with_env_overrides KURIA_LLM_PROVIDER: nil do
      provider_classes = Provider::Registry.for_concept(:llm).providers.map(&:class)
      assert_includes provider_classes, Provider::Opencode
    end

    with_env_overrides KURIA_LLM_PROVIDER: "ruby_llm" do
      provider_classes = Provider::Registry.for_concept(:llm).providers.map(&:class)
      assert_equal [ Provider::RubyLlm ], provider_classes
    end
  end

  test "registry returns nil for ruby_llm when the switch is off" do
    with_env_overrides KURIA_LLM_PROVIDER: nil do
      assert_nil Provider::Registry.get_provider(:ruby_llm)
    end
  end
end
