require "test_helper"

class AssistantTest < ActiveSupport::TestCase
  include ProviderTestHelper

  # Deterministic stand-ins for the RubyLLM gem boundary so the end-to-end
  # RubyLLM path never calls a live model API.
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
    @chat = chats(:two)
    @message = @chat.messages.create!(
      type: "UserMessage",
      content: "What is my net worth?",
      ai_model: "opencode/minimax-m2.5-free"
    )
    @assistant = Assistant.for_chat(@chat)
    @provider = mock
  end

  test "errors get added to chat" do
    @assistant.expects(:get_model_provider).with("opencode/minimax-m2.5-free").returns(@provider)

    error = StandardError.new("test error")
    @provider.expects(:chat_response).returns(provider_error_response(error))

    @chat.expects(:add_error).with(error).once

    assert_no_difference "AssistantMessage.count" do
      @assistant.respond_to(@message)
    end
  end

  test "responds to basic prompt" do
    @assistant.expects(:get_model_provider).with("opencode/minimax-m2.5-free").returns(@provider)

    text_chunk = provider_text_chunk("Your net worth is $50,000.")
    response_data = Provider::LlmConcept::ChatResponse.new(
      id: "msg_1",
      model: "opencode/minimax-m2.5-free",
      messages: [ provider_message(id: "msg_1", text: "Your net worth is $50,000.") ],
      function_requests: []
    )
    response_chunk = Provider::LlmConcept::ChatStreamChunk.new(type: "response", data: response_data)

    response = provider_success_response(response_data)

    @provider.expects(:chat_response).with do |message, **options|
      options[:streamer].call(text_chunk)
      options[:streamer].call(response_chunk)
      true
    end.returns(response)

    assert_difference "AssistantMessage.count", 1 do
      @assistant.respond_to(@message)
      message = @chat.messages.ordered.where(type: "AssistantMessage").last
      assert_equal "Your net worth is $50,000.", message.content
    end
  end

  test "get_model_provider returns the enabled provider that supports the model reference" do
    unsupported = mock
    supported = mock
    unsupported.expects(:supports_model?).with("openai/gpt-4o").returns(false)
    supported.expects(:supports_model?).with("openai/gpt-4o").returns(true)
    @assistant.stubs(:registry).returns(stub(providers: [ unsupported, supported ]))

    assert_equal supported, @assistant.get_model_provider("openai/gpt-4o")
  end

  test "get_model_provider raises a clear registry error when no enabled provider supports the reference" do
    provider = mock
    provider.expects(:supports_model?).with("openai/gpt-4o").returns(false)
    @assistant.stubs(:registry).returns(stub(providers: [ provider ]))

    error = assert_raises(Provider::Registry::Error) do
      @assistant.get_model_provider("openai/gpt-4o")
    end
    assert_match(/No enabled LLM provider supports model reference 'openai\/gpt-4o'/, error.message)
  end

  test "respond_to with an unsupported reference adds the registry error to the chat and persists no message" do
    @message.update!(ai_model: "openai/gpt-4o")
    provider = mock
    provider.expects(:supports_model?).with("openai/gpt-4o").returns(false)
    @assistant.stubs(:registry).returns(stub(providers: [ provider ]))
    @chat.expects(:add_error).with(instance_of(Provider::Registry::Error)).once

    assert_no_difference "AssistantMessage.count" do
      @assistant.respond_to(@message)
    end
  end

  test "routes a supported openai reference through RubyLlm and persists one streamed message when the switch is enabled" do
    @message.update!(ai_model: "openai/gpt-4o")

    final_message = FakeMessage.new(content: "Your net worth is $50,000.", id: "msg_ruby_1")
    chat_fake = FakeChat.new(final_message: final_message, chunks: [ FakeChunk.new(content: "Your net worth is $50,000.") ])
    RubyLLM.stubs(:context).yields(FakeConfig.new).returns(FakeContext.new(chat_fake))

    with_env_overrides KURIA_LLM_PROVIDER: "ruby_llm", OPENAI_API_KEY: "test-openai-key" do
      assert_difference "AssistantMessage.count", 1 do
        @assistant.respond_to(@message)
      end
    end

    message = @chat.messages.ordered.where(type: "AssistantMessage").last
    assert_equal "Your net worth is $50,000.", message.content
    assert_equal "openai/gpt-4o", message.ai_model
  end

  test "fails closed for an unsupported reference when RubyLlm is enabled" do
    @message.update!(ai_model: "anthropic/claude-3-5-sonnet")
    @chat.expects(:add_error).with(instance_of(Provider::Registry::Error)).once

    with_env_overrides KURIA_LLM_PROVIDER: "ruby_llm" do
      assert_no_difference "AssistantMessage.count" do
        @assistant.respond_to(@message)
      end
    end
  end

  test "routes an opencode reference through OpenCode when the switch is unset" do
    client = stub_opencode_client
    client.expects(:create_session).with(title: "What is my net worth?").returns({ "id" => "sess_default" })
    client.expects(:send_message).with(
      "sess_default",
      content: "What is my net worth?",
      model: { providerID: "opencode", modelID: "minimax-m2.5-free" },
      system: anything
    ).returns(opencode_message_response(id: "msg_default", content: "OpenCode default answer."))

    with_env_overrides KURIA_LLM_PROVIDER: nil do
      assert_difference "AssistantMessage.count", 1 do
        @assistant.respond_to(@message)
      end
    end

    message = @chat.messages.ordered.where(type: "AssistantMessage").last
    assert_equal "OpenCode default answer.", message.content
    assert_equal "opencode/minimax-m2.5-free", message.ai_model
  end

  test "routes an opencode reference through OpenCode when the switch is set to opencode" do
    client = stub_opencode_client
    client.expects(:create_session).with(title: "What is my net worth?").returns({ "id" => "sess_explicit" })
    client.expects(:send_message).with(
      "sess_explicit",
      content: "What is my net worth?",
      model: { providerID: "opencode", modelID: "minimax-m2.5-free" },
      system: anything
    ).returns(opencode_message_response(id: "msg_explicit", content: "OpenCode explicit answer."))

    with_env_overrides KURIA_LLM_PROVIDER: "opencode" do
      assert_difference "AssistantMessage.count", 1 do
        @assistant.respond_to(@message)
      end
    end

    message = @chat.messages.ordered.where(type: "AssistantMessage").last
    assert_equal "OpenCode explicit answer.", message.content
    assert_equal "opencode/minimax-m2.5-free", message.ai_model
  end

  test "fails closed for a foreign openai reference when the switch is unset" do
    @message.update!(ai_model: "openai/gpt-4o")
    stub_opencode_client
    @chat.expects(:add_error).with(instance_of(Provider::Registry::Error)).once

    with_env_overrides KURIA_LLM_PROVIDER: nil do
      assert_no_difference "AssistantMessage.count" do
        @assistant.respond_to(@message)
      end
    end
  end

  test "fails closed for an opencode_go reference when the switch is unset" do
    @message.update!(ai_model: "opencode_go/grok-4-fast")
    stub_opencode_client
    @chat.expects(:add_error).with(instance_of(Provider::Registry::Error)).once

    with_env_overrides KURIA_LLM_PROVIDER: nil do
      assert_no_difference "AssistantMessage.count" do
        @assistant.respond_to(@message)
      end
    end
  end

  test "routes an opencode_go reference through RubyLlm and persists one streamed message when the switch is enabled" do
    @message.update!(ai_model: "opencode_go/grok-4-fast")

    final_message = FakeMessage.new(content: "Hello from Go.", id: "msg_go_1")
    chat_fake = FakeChat.new(final_message: final_message, chunks: [ FakeChunk.new(content: "Hello from Go.") ])
    RubyLLM.stubs(:context).yields(FakeConfig.new).returns(FakeContext.new(chat_fake))

    with_env_overrides KURIA_LLM_PROVIDER: "ruby_llm", OPENCODE_GO_API_KEY: "test-go-key" do
      assert_difference "AssistantMessage.count", 1 do
        @assistant.respond_to(@message)
      end
    end

    message = @chat.messages.ordered.where(type: "AssistantMessage").last
    assert_equal "Hello from Go.", message.content
    assert_equal "opencode_go/grok-4-fast", message.ai_model
  end

  private
    def provider_message(id:, text:)
      Provider::LlmConcept::ChatMessage.new(id: id, output_text: text)
    end

    def provider_text_chunk(text)
      Provider::LlmConcept::ChatStreamChunk.new(type: "output_text", data: text)
    end

    def stub_opencode_client
      client = mock("opencode_client")
      Provider::Opencode::Client.stubs(:new).returns(client)
      client
    end

    def opencode_message_response(id:, content:)
      {
        "info" => {
          "id" => id,
          "role" => "assistant",
          "model" => { "providerID" => "opencode", "modelID" => "minimax-m2.5-free" }
        },
        "parts" => [
          { "type" => "text", "content" => content }
        ]
      }
    end
end
