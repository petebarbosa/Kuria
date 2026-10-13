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

    # The OpenCode Go branch clears these so a Go request never inherits the
    # deployment's OpenAI billing identity.
    def openai_organization_id=(value)
      @openai_organization_id = value
    end

    def openai_project_id=(value)
      @openai_project_id = value
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
      ai_model: "openai/gpt-4o"
    )
    @assistant = Assistant.for_chat(@chat)
    @provider = mock
  end

  test "errors get added to chat" do
    @assistant.expects(:get_model_provider).with("openai/gpt-4o").returns(@provider)

    error = StandardError.new("test error")
    @provider.expects(:chat_response).returns(provider_error_response(error))

    @chat.expects(:add_error).with(error).once

    assert_no_difference "AssistantMessage.count" do
      @assistant.respond_to(@message)
    end
  end

  test "responds to basic prompt" do
    @assistant.expects(:get_model_provider).with("openai/gpt-4o").returns(@provider)

    text_chunk = provider_text_chunk("Your net worth is $50,000.")
    response_data = Provider::LlmConcept::ChatResponse.new(
      id: "msg_1",
      model: "openai/gpt-4o",
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
    provider = mock
    provider.expects(:supports_model?).with("openai/gpt-4o").returns(false)
    @assistant.stubs(:registry).returns(stub(providers: [ provider ]))
    @chat.expects(:add_error).with(instance_of(Provider::Registry::Error)).once

    assert_no_difference "AssistantMessage.count" do
      @assistant.respond_to(@message)
    end
  end

  test "respond_to fails closed for an uncatalogued reference without contacting a model API" do
    # The real RubyLLM provider resolves manifest membership without a network
    # call, so this exercises the registry routing end to end.
    @message.update!(ai_model: "anthropic/claude-3-5-sonnet")
    @chat.expects(:add_error).with(instance_of(Provider::Registry::Error)).once

    assert_no_difference "AssistantMessage.count" do
      @assistant.respond_to(@message)
    end
  end

  test "routes a supported openai reference through RubyLlm and persists one streamed message" do
    @message.update!(ai_model: "openai/gpt-4o")
    stub_live_catalog_admission

    final_message = FakeMessage.new(content: "Your net worth is $50,000.", id: "msg_ruby_1")
    chat_fake = FakeChat.new(final_message: final_message, chunks: [ FakeChunk.new(content: "Your net worth is $50,000.") ])
    RubyLLM.stubs(:context).yields(FakeConfig.new).returns(FakeContext.new(chat_fake))

    assert_assistant_message_persisted(
      OPENAI_API_KEY: "test-openai-key",
      content: "Your net worth is $50,000.",
      ai_model: "openai/gpt-4o"
    )
  end

  test "routes a supported opencode_go reference through RubyLlm and persists one streamed message" do
    @message.update!(ai_model: "opencode_go/glm-5.3-flash")
    stub_live_catalog_admission

    final_message = FakeMessage.new(content: "Hello from Go.", id: "msg_go_1")
    chat_fake = FakeChat.new(final_message: final_message, chunks: [ FakeChunk.new(content: "Hello from Go.") ])
    RubyLLM.stubs(:context).yields(FakeConfig.new).returns(FakeContext.new(chat_fake))

    assert_assistant_message_persisted(
      OPENCODE_GO_API_KEY: "test-go-key",
      content: "Hello from Go.",
      ai_model: "opencode_go/glm-5.3-flash"
    )
  end

  # --- Observable streaming contract (issue #10) -------------------------
  # These exercise the Chat/Assistant boundary through provider-independent
  # ChatStreamChunks: the broadcast order the user sees and the single message
  # that survives a reload. No RubyLLM internals or prompt prose are asserted.

  test "broadcasts provider chunks in order and persists one authoritative message with completed metadata" do
    @assistant.expects(:get_model_provider).with("openai/gpt-4o").returns(@provider)

    completed = provider_response(id: "msg_completed", text: "Alpha Beta Gamma")
    @provider.expects(:chat_response).with do |_message, **options|
      options[:streamer].call(provider_text_chunk("Alpha"))
      options[:streamer].call(provider_text_chunk(" Beta"))
      options[:streamer].call(provider_text_chunk(" Gamma"))
      options[:streamer].call(provider_stream_chunk(completed))
      true
    end.returns(provider_success_response(completed))

    streams = capture_turbo_stream_broadcasts(@chat) do
      assert_difference "AssistantMessage.count", 1 do
        @assistant.respond_to(@message)
      end
    end

    visible = assistant_message_contents(streams)

    # Provider order, appended once: every broadcast extends the previous one.
    assert_equal [ "Alpha", "Alpha Beta", "Alpha Beta Gamma" ], visible.uniq
    visible.uniq.each_cons(2) do |previous, current|
      assert current.start_with?(previous), "expected #{current.inspect} to extend #{previous.inspect}"
    end

    # Reload parity: the single persisted message equals the final visible text.
    persisted = Chat.find(@chat.id).messages.ordered.where(type: "AssistantMessage").sole
    assert_equal "Alpha Beta Gamma", persisted.content
    assert_equal persisted.content, visible.last

    # Final metadata comes from the completed provider message, not a chunk.
    assert_equal "msg_completed", persisted.provider_id
    assert_equal "complete", persisted.status
  end

  test "finalizes content from the completed provider message when it extends the streamed chunks" do
    @assistant.expects(:get_model_provider).with("openai/gpt-4o").returns(@provider)

    completed = provider_response(id: "msg_final", text: "Alpha Beta Gamma")
    @provider.expects(:chat_response).with do |_message, **options|
      options[:streamer].call(provider_text_chunk("Alpha"))
      options[:streamer].call(provider_text_chunk(" Beta"))
      true
    end.returns(provider_success_response(completed))

    streams = capture_turbo_stream_broadcasts(@chat) do
      assert_difference "AssistantMessage.count", 1 do
        @assistant.respond_to(@message)
      end
    end

    persisted = @chat.messages.ordered.where(type: "AssistantMessage").sole
    assert_equal "Alpha Beta Gamma", persisted.content
    assert_equal persisted.content, assistant_message_contents(streams).last
  end

  test "removes the thinking indicator once, before any streamed content, on success" do
    @assistant.expects(:get_model_provider).with("openai/gpt-4o").returns(@provider)

    completed = provider_response(id: "msg_1", text: "Alpha Beta")
    @provider.expects(:chat_response).with do |_message, **options|
      options[:streamer].call(provider_text_chunk("Alpha"))
      options[:streamer].call(provider_text_chunk(" Beta"))
      true
    end.returns(provider_success_response(completed))

    streams = capture_turbo_stream_broadcasts(@chat) { @assistant.respond_to(@message) }

    removes = thinking_indicator_removes(streams)
    assert_equal 1, removes.size

    remove_index = streams.index(removes.first)
    first_content_index = streams.index { |stream| stream["action"] != "remove" }
    assert remove_index < first_content_index, "thinking must stop before visible content is broadcast"
  end

  test "removes the thinking indicator and persists no message when the provider fails" do
    @assistant.expects(:get_model_provider).with("openai/gpt-4o").returns(@provider)

    error = StandardError.new("provider failure")
    @provider.expects(:chat_response).returns(provider_error_response(error))
    @chat.expects(:add_error).with(error).once

    streams = capture_turbo_stream_broadcasts(@chat) do
      assert_no_difference "AssistantMessage.count" do
        @assistant.respond_to(@message)
      end
    end

    assert_equal 1, thinking_indicator_removes(streams).size
  end

  test "persists the completed message and stops thinking when the provider streams no chunks" do
    @assistant.expects(:get_model_provider).with("openai/gpt-4o").returns(@provider)

    completed = provider_response(id: "msg_only", text: "Complete answer")
    @provider.expects(:chat_response).returns(provider_success_response(completed))

    streams = capture_turbo_stream_broadcasts(@chat) do
      assert_difference "AssistantMessage.count", 1 do
        @assistant.respond_to(@message)
      end
    end

    persisted = @chat.messages.ordered.where(type: "AssistantMessage").sole
    assert_equal "Complete answer", persisted.content
    assert_equal "msg_only", persisted.provider_id
    assert_equal [ "Complete answer" ], assistant_message_contents(streams).uniq
    assert_equal 1, thinking_indicator_removes(streams).size
  end

  private
    # The visible text of every partial the assistant message broadcasts, in
    # broadcast order (thinking/remove frames excluded).
    def assistant_message_contents(streams)
      streams
        .reject { |stream| stream["action"] == "remove" }
        .map { |stream| Nokogiri::HTML5.fragment(stream.at("template")&.content.to_s).text.squish }
    end

    def thinking_indicator_removes(streams)
      streams.select { |stream| stream["action"] == "remove" && stream["target"] == "thinking-indicator" }
    end

    def provider_response(id:, text:, model: "openai/gpt-4o")
      Provider::LlmConcept::ChatResponse.new(
        id: id,
        model: model,
        messages: [ provider_message(id: id, text: text) ],
        function_requests: []
      )
    end

    def provider_stream_chunk(response)
      Provider::LlmConcept::ChatStreamChunk.new(type: "response", data: response)
    end

    def provider_message(id:, text:)
      Provider::LlmConcept::ChatMessage.new(id: id, output_text: text)
    end

    def provider_text_chunk(text)
      Provider::LlmConcept::ChatStreamChunk.new(type: "output_text", data: text)
    end

    # The catalog's live admission is the only network boundary on the RubyLLM
    # path; stub it so the streamed-response tests stay offline/deterministic.
    def stub_live_catalog_admission
      Provider::RubyLlm::Catalog.any_instance.stubs(:available?).returns(true)
    end

    def assert_assistant_message_persisted(content:, ai_model:, **overrides)
      with_env_overrides overrides do
        assert_difference "AssistantMessage.count", 1 do
          @assistant.respond_to(@message)
        end
      end

      message = @chat.messages.ordered.where(type: "AssistantMessage").last
      assert_equal content, message.content
      assert_equal ai_model, message.ai_model
    end
end
