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

    # Exact broadcast sequence: the thinking indicator stops once, the message
    # is appended once, then updated once per appended chunk, then replaced by
    # the finalization broadcast.
    assert_equal %w[remove append update update update], streams.map { |stream| stream["action"] }

    visible = assistant_message_contents(streams)
    assert_equal [ "Alpha", "Alpha Beta", "Alpha Beta Gamma", "Alpha Beta Gamma" ], visible
    assert_streamed_in_order(visible)

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

    visible = assistant_message_contents(streams)
    # The provided chunks stop at "Alpha Beta"; the final broadcast replaces
    # them with the completed message's text.
    assert_equal [ "Alpha", "Alpha Beta", "Alpha Beta Gamma" ], visible
    assert_streamed_in_order(visible)

    persisted = @chat.messages.ordered.where(type: "AssistantMessage").sole
    assert_equal "Alpha Beta Gamma", persisted.content
    assert_equal persisted.content, visible.last
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
    assert_equal [ "Complete answer" ], assistant_message_contents(streams)
    assert_equal 1, thinking_indicator_removes(streams).size
  end

  test "fails closed when a successful provider response carries no completed message" do
    @assistant.expects(:get_model_provider).with("openai/gpt-4o").returns(@provider)

    @provider.expects(:chat_response).returns(
      Provider::Response.new(success?: true, data: nil, error: nil)
    )
    @chat.expects(:add_error).with(instance_of(Provider::Error)).once

    streams = capture_turbo_stream_broadcasts(@chat) do
      assert_no_difference "AssistantMessage.count" do
        @assistant.respond_to(@message)
      end
    end

    assert_equal 1, thinking_indicator_removes(streams).size
  end

  test "preserves newlines and repeated spaces in streamed and persisted content" do
    @assistant.expects(:get_model_provider).with("openai/gpt-4o").returns(@provider)

    completed = provider_response(id: "msg_ws", text: "Line one\nLine two  spaced")
    @provider.expects(:chat_response).with do |_message, **options|
      options[:streamer].call(provider_text_chunk("Line one"))
      options[:streamer].call(provider_text_chunk("\nLine two  spaced"))
      true
    end.returns(provider_success_response(completed))

    streams = capture_turbo_stream_broadcasts(@chat) do
      assert_difference "AssistantMessage.count", 1 do
        @assistant.respond_to(@message)
      end
    end

    persisted = @chat.messages.ordered.where(type: "AssistantMessage").sole
    assert_equal "Line one\nLine two  spaced", persisted.content

    visible = assistant_message_contents(streams)
    assert_equal [ "Line one", "Line one\nLine two  spaced", "Line one\nLine two  spaced" ], visible
    # Rendering must not collapse the newline or the repeated space.
    assert_includes visible.last, "\n"
    assert_includes visible.last, "  "
  end

  test "records a RubyLLM response id as the latest response only, never as an opencode session" do
    @chat.update!(opencode_session_id: "legacy_sess_123")
    @assistant.expects(:get_model_provider).with("openai/gpt-4o").returns(@provider)

    completed = provider_response(id: "ruby_llm_deadbeef", text: "Answer")
    captured_options = nil
    @provider.expects(:chat_response).with do |_message, **options|
      captured_options = options
      options[:streamer].call(provider_text_chunk("Answer"))
      options[:streamer].call(provider_stream_chunk(completed))
      true
    end.returns(provider_success_response(completed))

    @assistant.respond_to(@message)

    assert_nil captured_options[:previous_response_id],
      "a RubyLLM request must not inherit a legacy opencode session id"

    @chat.reload
    assert_equal "ruby_llm_deadbeef", @chat.latest_assistant_response_id
    assert_equal "legacy_sess_123", @chat.opencode_session_id,
      "RubyLLM must not overwrite the legacy opencode session"
  end

  test "writes a legacy OpenCode response id as the opencode session and latest response" do
    opencode = build_opencode_provider
    @message.update!(ai_model: "opencode/big-pickle")
    @assistant.expects(:get_model_provider).with("opencode/big-pickle").returns(opencode)

    completed = provider_response(id: "msg_legacy", text: "Legacy answer", model: "opencode/big-pickle")
    captured_options = nil
    opencode.expects(:chat_response).with do |_message, **options|
      captured_options = options
      options[:streamer].call(provider_text_chunk("Legacy answer"))
      options[:streamer].call(provider_stream_chunk(completed))
      true
    end.returns(provider_success_response(completed))

    @assistant.respond_to(@message)

    assert_nil captured_options[:previous_response_id],
      "a fresh legacy OpenCode chat starts a new session"

    @chat.reload
    assert_equal "msg_legacy", @chat.opencode_session_id
    assert_equal "msg_legacy", @chat.latest_assistant_response_id
  end

  test "threads and preserves an existing opencode session for the legacy OpenCode provider" do
    opencode = build_opencode_provider
    @message.update!(ai_model: "opencode/big-pickle")
    @assistant.expects(:get_model_provider).with("opencode/big-pickle").returns(opencode)
    @chat.update!(opencode_session_id: "legacy_sess_9")

    completed = provider_response(id: "msg_legacy_2", text: "More", model: "opencode/big-pickle")
    captured_options = nil
    opencode.expects(:chat_response).with do |_message, **options|
      captured_options = options
      true
    end.returns(provider_success_response(completed))

    @assistant.respond_to(@message)

    assert_equal "legacy_sess_9", captured_options[:previous_response_id]

    @chat.reload
    assert_equal "legacy_sess_9", @chat.opencode_session_id,
      "the historical opencode session must be preserved"
    assert_equal "msg_legacy_2", @chat.latest_assistant_response_id
  end

  private
    # The visible assistant body of every broadcast, in broadcast order
    # (thinking/remove frames excluded). Text is read from the rendered
    # paragraph without squish or uniq, so duplicate and whitespace-corrupted
    # broadcasts stay observable to the assertions.
    def assistant_message_contents(streams)
      streams
        .reject { |stream| stream["action"] == "remove" }
        .map { |stream| rendered_assistant_text(stream) }
    end

    def rendered_assistant_text(stream)
      fragment = Nokogiri::HTML5.fragment(stream.at("template")&.inner_html.to_s)
      fragment.at_css(".prose > p")&.text
    end

    # Partial broadcasts must strictly extend each other and never repeat. The
    # final entry is the finalization broadcast and may intentionally replace
    # the streamed partial with the completed message's text.
    def assert_streamed_in_order(contents)
      partials = contents[0...-1]
      assert_equal partials, partials.uniq, "partial broadcasts must not repeat"
      partials.each_cons(2) do |previous, current|
        assert current.start_with?(previous), "expected #{current.inspect} to extend #{previous.inspect}"
      end
      assert contents.last.start_with?(partials.last), "expected the final broadcast to extend #{partials.last.inspect}"
    end

    # A real legacy OpenCode provider with its HTTP client stubbed, so
    # provider-identity checks (is_a?) see the genuine class without a network
    # dependency.
    def build_opencode_provider
      Provider::Opencode::Client.stubs(:new).returns(mock("opencode_client"))
      Provider::Opencode.new
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
