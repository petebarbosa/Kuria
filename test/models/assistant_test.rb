require "test_helper"

class AssistantTest < ActiveSupport::TestCase
  include ProviderTestHelper

  OPENAI_CHAT_URL = Provider::RubyLlm::OPENAI_BASE_URL + "/chat/completions"
  OPENCODE_GO_CHAT_URL = "https://opencode.ai/inference/go/openai/v1/chat/completions".freeze

  # Deterministic stand-ins for the RubyLLM gem boundary so the end-to-end
  # RubyLLM path never calls a live model API.
  class FakeConfig
    attr_reader :openai_api_key, :openai_api_base, :opencode_go_session_id
    attr_accessor :request_timeout, :max_retries, :retry_interval, :retry_max_interval,
      :retry_backoff_factor, :retry_interval_randomness, :faraday_adapter, :instrumenter

    def openai_api_key=(value)
      @openai_api_key = value
    end

    def openai_api_base=(value)
      @openai_api_base = value
    end

    def opencode_go_session_id=(value)
      @opencode_go_session_id = value
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
    attr_reader :prompt, :instructions, :tools, :tool_options

    def initialize(final_message:, chunks: [])
      @final_message = final_message
      @chunks = chunks
    end

    def with_instructions(instructions)
      @instructions = instructions
      self
    end

    def with_tools(*tools)
      @tools = tools.flatten
      self
    end

    def with_tool_options(**options)
      @tool_options = options
      self
    end

    def add_message(_message)
      self
    end

    def after_message(&block)
      (@after_message_callbacks ||= []) << block
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

  # Issue #16 seam: a provider that streams text chunks and then raises
  # (e.g. RubyLLM::ServerError) — the failure surfaces out of the streaming
  # request itself, after partial content has already been delivered and
  # persisted by the streamer.
  class RaisingStreamProvider
    attr_reader :error

    def initialize(error, chunks: [])
      @error = error
      @chunks = chunks
    end

    def supports_model?(_model)
      true
    end

    def chat_response(_prompt, streamer:, **)
      @chunks.each { |chunk| streamer.call(chunk) }
      raise error
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

  test "keeps one opaque Go session per chat across assistant turns and separates chats" do
    Provider::RubyLlm::Catalog.any_instance.stubs(:available?).returns(true)

    sessions = []
    stub_request(:post, OPENCODE_GO_CHAT_URL).to_return do |request|
      sessions << header_value(request, "x-opencode-session")
      {
        status: 200,
        headers: { "Content-Type" => "text/event-stream" },
        body: sse_body(content_chunk("Go reply"), finish_chunk("stop"), "[DONE]")
      }
    end

    @message.update!(ai_model: "opencode_go/glm-5.3-flash")
    second_message = @chat.messages.create!(
      type: "UserMessage",
      content: "And again?",
      ai_model: "opencode_go/glm-5.3-flash"
    )
    other_chat = Chat.create!(title: "Other conversation", user: @chat.user)
    other_message = other_chat.messages.create!(
      type: "UserMessage",
      content: "Other chat prompt",
      ai_model: "opencode_go/glm-5.3-flash"
    )

    with_env_overrides OPENCODE_GO_API_KEY: "test-go-key" do
      @chat.assistant.respond_to(@message)
      @chat.assistant.respond_to(second_message)
      other_chat.assistant.respond_to(other_message)
    end

    assert_nil @chat.reload.error
    assert_nil other_chat.reload.error
    assert_equal 3, sessions.size
    assert sessions.all? { |session| session.match?(/\Ases_[0-9a-f]{32}\z/) }

    # Fresh provider instances within the same Chat derive the same session;
    # another Chat never shares it.
    assert_equal sessions[0], sessions[1]
    refute_equal sessions[0], sessions[2]
    refute_equal "ses_#{@chat.id}", sessions[0]
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

  # --- Partial-stream recovery (issue #16) -------------------------------
  # The streamer persists and broadcasts text chunks into an AssistantMessage
  # before the provider response is complete. When the provider fails
  # mid-stream the failure must discard exactly this attempt's persisted
  # partial message — never a historical message, never a finalized reply —
  # stop the thinking indicator exactly once, and land the error in the chat
  # envelope so the user can retry the turn.

  test "discards the attempt's partial assistant message when the provider raises mid-stream" do
    # Historical traffic predates this attempt's user message, so the last
    # conversation message stays the user's own after the partial is discarded.
    past_answer = @chat.messages.create!(
      type: "AssistantMessage",
      content: "Earlier answer",
      ai_model: "openai/gpt-4o",
      created_at: @message.created_at - 1.hour
    )

    error = RubyLLM::ServerError.new("provider exploded mid-stream")
    provider = RaisingStreamProvider.new(
      error,
      chunks: [ provider_text_chunk("Partial "), provider_text_chunk("answer") ]
    )
    @assistant.expects(:get_model_provider).with("openai/gpt-4o").returns(provider)

    streams = capture_turbo_stream_broadcasts(@chat) do
      assert_no_difference "AssistantMessage.count" do
        @assistant.respond_to(@message)
      end
    end

    # The thinking indicator is removed exactly once even though the failure
    # happened after visible content was already delivered.
    assert_equal 1, thinking_indicator_removes(streams).size

    # The partial the client already received is removed through the same
    # broadcast mechanism that painted it.
    streamed_targets = streams
      .map { |stream| stream["target"].to_s }
      .select { |target| target.start_with?("assistant_message_") }
      .uniq
    assert_equal 1, streamed_targets.size, "only this attempt's partial message may appear in the stream"
    removed_targets = streams.select { |stream| stream["action"] == "remove" }.map { |stream| stream["target"].to_s }
    assert_includes removed_targets, streamed_targets.first

    # Nothing from the failed attempt survives; historical messages are intact.
    reloaded = Chat.find(@chat.id)
    assert_equal [ past_answer.id ], reloaded.messages.where(type: "AssistantMessage").order(:id).pluck(:id)
    assert_equal "Earlier answer", reloaded.messages.where(type: "AssistantMessage").sole.reload.content

    # The failure is recorded in the chat's error envelope.
    assert reloaded.reload.error.present?, "the chat must record the provider failure"

    # With no surviving assistant message the retry gate sees the user's
    # message last again.
    assert_predicate reloaded, :needs_assistant_response?,
      "a failed streaming attempt must not block the retry gate"
  end

  test "removes the partial and records the provider error when the removal broadcast fails" do
    past_answer = @chat.messages.create!(
      type: "AssistantMessage",
      content: "Earlier answer",
      ai_model: "openai/gpt-4o",
      created_at: @message.created_at - 1.hour
    )

    error = RubyLLM::ServerError.new("provider exploded mid-stream")
    provider = RaisingStreamProvider.new(
      error,
      chunks: [ provider_text_chunk("Partial "), provider_text_chunk("answer") ]
    )
    @assistant.expects(:get_model_provider).with("openai/gpt-4o").returns(provider)
    AssistantMessage.any_instance.stubs(:broadcast_remove_to).raises(StandardError, "stream unavailable")

    streams = capture_turbo_stream_broadcasts(@chat) do
      assert_no_difference "AssistantMessage.count" do
        @assistant.respond_to(@message)
      end
    end

    assert_equal 1, thinking_indicator_removes(streams).size

    # The persisted row is the source of truth: a failed removal broadcast must
    # not leave this attempt's partial behind, and historical replies stay.
    reloaded = Chat.find(@chat.id)
    assert_equal [ past_answer.id ], reloaded.messages.where(type: "AssistantMessage").order(:id).pluck(:id)
    assert_predicate reloaded, :needs_assistant_response?,
      "a failed removal broadcast must not block the retry gate"

    # The original provider failure is recorded, not the broadcast failure.
    assert_equal error.to_json, reloaded.error
  end

  test "persists nothing when the provider raises before streaming any content" do
    provider = RaisingStreamProvider.new(RubyLLM::ServerError.new("failed immediately"))
    @assistant.expects(:get_model_provider).with("openai/gpt-4o").returns(provider)

    streams = capture_turbo_stream_broadcasts(@chat) do
      assert_no_difference "AssistantMessage.count" do
        @assistant.respond_to(@message)
      end
    end

    assert_equal 1, thinking_indicator_removes(streams).size
    assert @chat.reload.error.present?, "the chat must record the provider failure"
    assert_predicate Chat.find(@chat.id), :needs_assistant_response?,
      "a failed attempt must not block the retry gate"
  end

  test "keeps a finalized reply when a later persistence step fails" do
    @assistant.expects(:get_model_provider).with("openai/gpt-4o").returns(@provider)

    completed = provider_response(id: "msg_final", text: "Alpha Beta")
    @provider.expects(:chat_response).with do |_message, **options|
      options[:streamer].call(provider_text_chunk("Alpha"))
      options[:streamer].call(provider_text_chunk(" Beta"))
      true
    end.returns(provider_success_response(completed))

    @chat.stubs(:update_latest_response!).raises(StandardError, "chat persistence exploded")

    capture_turbo_stream_broadcasts(@chat) do
      @assistant.respond_to(@message)
    end

    # The completed reply is never mistaken for a failed attempt's partial and
    # is not destroyed by the late-failure error path.
    persisted = @chat.messages.ordered.where(type: "AssistantMessage").sole
    assert_equal "Alpha Beta", persisted.content
    assert_equal "complete", persisted.status
    assert_equal "msg_final", persisted.provider_id
  end

  test "RubyLLM instructions bind the read-only accounts tool directly without model family selection" do
    stub_live_catalog_admission
    stub_openai_stream(
      sse_body(content_chunk("Hello."), finish_chunk("stop"), "[DONE]")
    )

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @assistant.respond_to(@message)
    end

    assert_nil @chat.reload.error

    developer_content = nil
    assert_requested(:post, OPENAI_CHAT_URL) do |request|
      developer_content = JSON.parse(request.body).fetch("messages")
        .find { |message| message["role"] == "developer" }
        &.fetch("content")
      true
    end

    assert_includes developer_content, "get_accounts"
    assert_match(/read-only/i, developer_content)
    assert_match(/authenticated/i, developer_content)
    assert_match(/(?:never|must not|do not).*family_id/im, developer_content)
    refute_match(/family_id is:/i, developer_content)
    refute_includes developer_content, @chat.user.family.id
  end

  # --- tool-call audit and recovery (phase 3) -----------------------------

  test "audits the bound family's get_accounts call before dispatch and persists one final streamed reply" do
    account = create_family_account("Bound family checking", 5123.45)
    other_account = create_other_family_account("Other family secret account", 987_654.32)

    stub_live_catalog_admission
    stub_openai_stream(
      sse_body(
        tool_call_chunk([ { id: "call_accounts", name: "get_accounts", arguments: "{}" } ]),
        finish_chunk("tool_calls"),
        "[DONE]"
      ),
      sse_body(
        content_chunk("Your accounts are available."),
        finish_chunk("stop"),
        "[DONE]"
      )
    )

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @assistant.respond_to(@message)
    end

    assert_nil @chat.reload.error

    owner = @chat.messages.where(type: "AssistantMessage").sole
    assert_equal "complete", owner.status
    assert_equal "Your accounts are available.", owner.content

    audit = owner.tool_calls.sole
    assert_equal "1:0", audit.provider_id
    assert_equal "call_accounts", audit.provider_call_id
    assert_equal "get_accounts", audit.function_name
    assert_equal({}, audit.function_arguments)
    assert_includes audit.function_result.fetch("accounts").map { |entry| entry["name"] }, account.name
    refute_includes audit.function_result.fetch("accounts").map { |entry| entry["name"] }, other_account.name

    assert_requested :post, OPENAI_CHAT_URL, times: 2
    assert_requested(:post, OPENAI_CHAT_URL) do |request|
      tool_messages = JSON.parse(request.body).fetch("messages").select { |message| message["role"] == "tool" }

      tool_messages.any? &&
        tool_messages.all? { |message| message["content"].include?(account.name) && !message["content"].include?(other_account.name) }
    end
  end

  test "rejects and audits a model-supplied family_id without querying accounts or leaking another family" do
    McpTools::GetAccounts.expects(:call).never
    other_account = create_other_family_account("Other family secret account", 987_654.32)

    stub_live_catalog_admission
    stub_openai_stream(
      sse_body(
        tool_call_chunk([ { id: "call_family", name: "get_accounts", arguments: '{"family_id":1}' } ]),
        finish_chunk("tool_calls"),
        "[DONE]"
      ),
      sse_body(content_chunk("I could not access those accounts."), finish_chunk("stop"), "[DONE]")
    )

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @assistant.respond_to(@message)
    end

    assert_nil @chat.reload.error
    audit = @chat.messages.where(type: "AssistantMessage").sole.tool_calls.sole
    assert_equal({ "family_id" => 1 }, audit.function_arguments)
    assert_equal "Account access is restricted to the authenticated family.", audit.function_result.fetch("error")

    assert_requested :post, OPENAI_CHAT_URL, times: 2
    assert_requested(:post, OPENAI_CHAT_URL) do |request|
      tool_message = JSON.parse(request.body).fetch("messages").find { |message| message["role"] == "tool" }

      tool_message && !tool_message["content"].include?(other_account.name)
    end
  end

  test "audits unexpected tool arguments as a fixed failure without executing a query" do
    McpTools::GetAccounts.expects(:call).never

    stub_live_catalog_admission
    stub_openai_stream(
      sse_body(
        tool_call_chunk([ { id: "call_extra", name: "get_accounts", arguments: '{"account_id":"anything"}' } ]),
        finish_chunk("tool_calls"),
        "[DONE]"
      ),
      sse_body(content_chunk("That request was invalid."), finish_chunk("stop"), "[DONE]")
    )

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @assistant.respond_to(@message)
    end

    assert_nil @chat.reload.error
    audit = @chat.messages.where(type: "AssistantMessage").sole.tool_calls.sole
    assert_equal({ "account_id" => "anything" }, audit.function_arguments)
    assert_equal "Invalid tool arguments.", audit.function_result.fetch("error")
  end

  test "audits an unknown tool and continues with its safe error result" do
    McpTools::GetAccounts.expects(:call).never

    stub_live_catalog_admission
    stub_openai_stream(
      sse_body(
        tool_call_chunk([ { id: "call_unknown", name: "get_accountz", arguments: "{}" } ]),
        finish_chunk("tool_calls"),
        "[DONE]"
      ),
      sse_body(content_chunk("That tool is unavailable."), finish_chunk("stop"), "[DONE]")
    )

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @assistant.respond_to(@message)
    end

    assert_nil @chat.reload.error
    audit = @chat.messages.where(type: "AssistantMessage").sole.tool_calls.sole
    assert_equal "get_accountz", audit.function_name
    assert_match(/unavailable tool/, audit.function_result.fetch("error"))

    assert_requested :post, OPENAI_CHAT_URL, times: 2
    assert_requested(:post, OPENAI_CHAT_URL) do |request|
      JSON.parse(request.body).fetch("messages").any? do |message|
        message["role"] == "tool" && message["content"].include?("unavailable tool")
      end
    end
  end

  test "rejects valid non-object tool arguments safely after auditing the call" do
    McpTools::GetAccounts.expects(:call).never

    stub_live_catalog_admission
    stub_openai_stream(
      sse_body(
        tool_call_chunk([ { id: "call_array", name: "get_accounts", arguments: "[]" } ]),
        finish_chunk("tool_calls"),
        "[DONE]"
      )
    )

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @assistant.respond_to(@message)
    end

    assert_requested :post, OPENAI_CHAT_URL, times: 1

    owner = @chat.messages.where(type: "AssistantMessage").sole
    assert_equal "failed", owner.status
    assert_equal "", owner.content
    refute_includes @chat.conversation_messages, owner

    audit = owner.tool_calls.sole
    assert_equal [], audit.function_arguments
    assert_equal "Tool call was not executed because the model returned arguments that are not a JSON object.",
      audit.function_result.fetch("error")
    assert_match(/not a JSON object/, @chat.reload.error)
  end

  test "recovers every malformed tool call in a rejected batch, audits raw arguments, and never executes" do
    McpTools::GetAccounts.expects(:call).never

    stub_live_catalog_admission
    stub_openai_stream(
      sse_body(
        tool_call_chunk([
          { id: "call_a", name: "get_accounts", arguments: '{"SECRET_RAW_ARGUMENT":' },
          { id: "call_b", name: "get_accounts", arguments: "not-json" }
        ]),
        tool_call_chunk([
          { arguments: "}" },
          { arguments: "-payload" }
        ]),
        finish_chunk("tool_calls"),
        "[DONE]"
      )
    )

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @assistant.respond_to(@message)
    end

    assert_requested :post, OPENAI_CHAT_URL, times: 1

    owner = @chat.messages.where(type: "AssistantMessage").sole
    assert_equal "failed", owner.status
    assert_equal "", owner.content
    refute_includes @chat.conversation_messages, owner

    audits = owner.tool_calls.order(:id)
    assert_equal %w[call_a call_b], audits.map(&:provider_call_id)
    assert_equal %w[1:0 1:1], audits.map(&:provider_id)
    assert_equal %w[get_accounts get_accounts], audits.map(&:function_name)
    assert_equal '{"SECRET_RAW_ARGUMENT":}', audits.first.function_arguments
    assert_equal "not-json-payload", audits.last.function_arguments
    assert audits.all? { |audit| audit.function_result.fetch("error").include?("malformed arguments") }

    # The raw model payload survives only in audit storage, never in the error.
    assert_match(/malformed tool call arguments/, @chat.reload.error)
    refute_match(/SECRET_RAW_ARGUMENT/, @chat.error)
    refute_match(/not-json-payload/, @chat.error)
  end

  test "audits a structurally malformed tool-call envelope before failing safely" do
    McpTools::GetAccounts.expects(:call).never

    stub_live_catalog_admission
    stub_openai_stream(
      sse_body(
        raw_tool_call_chunk([
          {
            "index" => 0,
            "id" => "call_structural",
            "type" => "function",
            "function" => "SECRET_STRUCTURAL_PAYLOAD"
          }
        ]),
        finish_chunk("tool_calls"),
        "[DONE]"
      )
    )

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @assistant.respond_to(@message)
    end

    assert_requested :post, OPENAI_CHAT_URL, times: 1

    owner = @chat.messages.where(type: "AssistantMessage").sole
    assert_equal "failed", owner.status
    assert_equal "", owner.content
    refute_includes @chat.conversation_messages, owner

    audit = owner.tool_calls.sole
    assert_equal "call_structural", audit.provider_call_id
    assert_equal "unknown_tool", audit.function_name
    assert_includes audit.function_arguments.to_s, "SECRET_STRUCTURAL_PAYLOAD"
    assert_match(/structurally malformed tool call/, audit.function_result.fetch("error"))

    # Raw model payload survives only in audit storage.
    assert_match(/structurally malformed tool call/, @chat.reload.error)
    refute_match(/SECRET_STRUCTURAL_PAYLOAD/, @chat.error)
  end

  test "audits observed tool calls when the same chunk later fails stream validation" do
    McpTools::GetAccounts.expects(:call).never

    tool_event = raw_tool_call_chunk([
      {
        "index" => 0,
        "id" => "call_bad_shape",
        "type" => "function",
        "function" => "SECRET_TRANSPORT_PAYLOAD"
      },
      {
        "index" => 1,
        "id" => "call_other",
        "type" => "function",
        "function" => { "name" => "get_accounts", "arguments" => "{}" }
      }
    ])
    body = [
      "data: #{tool_event.to_json}\n\n",
      "data: {bad\n\n"
    ].join

    stub_live_catalog_admission
    stub_openai_stream(body)

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @assistant.respond_to(@message)
    end

    assert_requested :post, OPENAI_CHAT_URL, times: 1

    owner = @chat.messages.where(type: "AssistantMessage").sole
    assert_equal "failed", owner.status
    assert_equal "", owner.content
    refute_includes @chat.conversation_messages, owner

    audits = owner.tool_calls.order(:id)
    assert_equal %w[call_bad_shape call_other], audits.map(&:provider_call_id)
    assert_equal %w[unknown_tool get_accounts], audits.map(&:function_name)
    assert audits.all? do |audit|
      audit.function_result.fetch("error").include?("not executed")
    end

    assert_match(/stream was malformed or incomplete/i, @chat.reload.error)
    refute_match(/SECRET_TRANSPORT_PAYLOAD/, @chat.error)
    assert_predicate @chat.reload, :needs_assistant_response?
  end

  test "does not duplicate an earlier completed audit when a later stream batch aborts validation" do
    account = create_family_account("Bound family checking", 5123.45)

    first = sse_body(
      tool_call_chunk([ { id: "call_round_one", name: "get_accounts", arguments: "{}" } ]),
      finish_chunk("tool_calls"),
      "[DONE]"
    )
    second_tool_event = raw_tool_call_chunk([
      {
        "index" => 0,
        "id" => "call_round_two",
        "type" => "function",
        "function" => { "name" => "get_accounts", "arguments" => "{}" }
      }
    ])
    second = [
      "data: #{second_tool_event.to_json}\n\n",
      "data: {bad\n\n"
    ].join

    stub_live_catalog_admission
    stub_openai_stream(first, second)

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @assistant.respond_to(@message)
    end

    assert_requested :post, OPENAI_CHAT_URL, times: 2

    owner = @chat.messages.where(type: "AssistantMessage").sole
    assert_equal "failed", owner.status
    assert_equal "", owner.content
    refute_includes @chat.conversation_messages, owner

    audits = owner.tool_calls.order(:id)
    assert_equal %w[call_round_one call_round_two], audits.map(&:provider_call_id)
    assert_equal 2, audits.map(&:provider_call_id).uniq.size

    completed = audits.first.function_result
    assert_includes completed.fetch("accounts").map { |entry| entry["name"] }, account.name
    assert_match(/stream was malformed or incomplete/i, audits.last.function_result.fetch("error"))
    assert_match(/stream was malformed or incomplete/i, @chat.reload.error)
    assert_predicate @chat.reload, :needs_assistant_response?
  end

  test "audits every identifiable call in a malformed batch beyond thirty-two" do
    McpTools::GetAccounts.expects(:call).never

    calls = Array.new(33) do |index|
      { id: "call_overflow_#{index}", name: "get_accounts", arguments: '{"broken":' }
    end

    stub_live_catalog_admission
    stub_openai_stream(
      sse_body(tool_call_chunk(calls), finish_chunk("tool_calls"), "[DONE]")
    )

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @assistant.respond_to(@message)
    end

    assert_requested :post, OPENAI_CHAT_URL, times: 1

    owner = @chat.messages.where(type: "AssistantMessage").sole
    assert_equal "failed", owner.status
    assert_equal "", owner.content

    audits = owner.tool_calls.order(:id)
    assert_equal 33, audits.size
    assert_equal calls.map { |call| call[:id] }, audits.map(&:provider_call_id)
    assert_equal "call_overflow_32", audits.last.provider_call_id
    assert audits.all? { |audit| audit.function_result.fetch("error").include?("malformed arguments") }
  end

  test "audits every call in an over-budget batch and rejects the whole batch before execution" do
    McpTools::GetAccounts.expects(:call).never

    calls = Array.new(Provider::RubyLlm::MAX_TOOL_CALLS_PER_RESPONSE + 1) do |index|
      { id: "call_#{index}", name: "get_accounts", arguments: "{}" }
    end

    stub_live_catalog_admission
    stub_openai_stream(
      sse_body(tool_call_chunk(calls), finish_chunk("tool_calls"), "[DONE]")
    )

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @assistant.respond_to(@message)
    end

    assert_requested :post, OPENAI_CHAT_URL, times: 1

    owner = @chat.messages.where(type: "AssistantMessage").sole
    assert_equal "failed", owner.status
    assert_equal "", owner.content

    audits = owner.tool_calls.order(:id)
    assert_equal calls.size, audits.size
    assert audits.all? { |audit| audit.function_result.fetch("error").include?("tool-call limit") }
    assert_match(/tool-call limit/, @chat.reload.error)
    assert_predicate @chat.reload, :needs_assistant_response?
  end

  test "enforces the tool-call budget cumulatively across rounds and preserves earlier results" do
    account = create_family_account("Bound family checking", 5123.45)

    first_calls = Array.new(3) do |index|
      { id: "call_first_#{index}", name: "get_accounts", arguments: "{}" }
    end
    second_calls = Array.new(3) do |index|
      { id: "call_second_#{index}", name: "get_accounts", arguments: "{}" }
    end

    stub_live_catalog_admission
    stub_openai_stream(
      sse_body(tool_call_chunk(first_calls), finish_chunk("tool_calls"), "[DONE]"),
      sse_body(tool_call_chunk(second_calls), finish_chunk("tool_calls"), "[DONE]"),
      sse_body(content_chunk("All calls completed."), finish_chunk("stop"), "[DONE]")
    )

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @assistant.respond_to(@message)
    end

    assert_requested :post, OPENAI_CHAT_URL, times: 2

    owner = @chat.messages.where(type: "AssistantMessage").sole
    assert_equal "failed", owner.status
    assert_equal "", owner.content
    refute_includes @chat.conversation_messages, owner

    audits = owner.tool_calls.order(:id)
    assert_equal 6, audits.size
    assert audits.first(3).all? { |audit| audit.function_result.fetch("accounts").any? { |entry| entry["name"] == account.name } }
    assert audits.last(3).all? { |audit| audit.function_result.fetch("error").include?("tool-call limit") }
    assert_match(/tool-call limit/, @chat.reload.error)
    assert_predicate @chat.reload, :needs_assistant_response?
  end

  test "keeps a completed tool audit when the provider fails on the following round" do
    account = create_family_account("Bound family checking", 5123.45)

    stub_live_catalog_admission
    stub_openai_stream(
      sse_body(
        tool_call_chunk([ { id: "call_accounts", name: "get_accounts", arguments: "{}" } ]),
        finish_chunk("tool_calls"),
        "[DONE]"
      ),
      { status: 500, headers: { "Content-Type" => "application/json" }, body: { error: { message: "boom" } }.to_json }
    )

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @assistant.respond_to(@message)
    end

    owner = @chat.messages.where(type: "AssistantMessage").sole
    assert_equal "failed", owner.status
    assert_equal "", owner.content
    refute_includes @chat.conversation_messages, owner

    audit = owner.tool_calls.sole
    assert_includes audit.function_result.fetch("accounts").map { |entry| entry["name"] }, account.name
    assert_match(/API error/, @chat.reload.error)
    assert_predicate @chat.reload, :needs_assistant_response?
  end

  test "removes streamed partial content but keeps the audit owner when a later round fails" do
    create_family_account("Bound family checking", 5123.45)

    stub_live_catalog_admission
    stub_openai_stream(
      sse_body(
        content_chunk("Partial answer. "),
        tool_call_chunk([ { id: "call_accounts", name: "get_accounts", arguments: "{}" } ]),
        finish_chunk("tool_calls"),
        "[DONE]"
      ),
      { status: 500, headers: { "Content-Type" => "application/json" }, body: { error: { message: "boom" } }.to_json }
    )

    streams = capture_turbo_stream_broadcasts(@chat) do
      with_env_overrides OPENAI_API_KEY: "test-openai-key" do
        @assistant.respond_to(@message)
      end
    end

    owner = @chat.messages.where(type: "AssistantMessage").sole
    assert_equal "failed", owner.status
    assert_equal "", owner.content
    refute_includes @chat.conversation_messages, owner
    assert_equal 1, owner.tool_calls.count

    removed_targets = streams.select { |stream| stream["action"] == "remove" }.map { |stream| stream["target"].to_s }
    assert_includes removed_targets, "assistant_message_#{owner.id}"
    assert_match(/API error/, @chat.reload.error)
    assert_predicate @chat.reload, :needs_assistant_response?
  end

  test "keeps repeated provider call ids distinct across tool-call rounds" do
    account = create_family_account("Bound family checking", 5123.45)

    stub_live_catalog_admission
    first = sse_body(
      tool_call_chunk([ { id: "call_repeated", name: "get_accounts", arguments: "{}" } ]),
      finish_chunk("tool_calls"),
      "[DONE]"
    )
    second = sse_body(
      tool_call_chunk([ { id: "call_repeated", name: "get_accounts", arguments: "{}" } ]),
      finish_chunk("tool_calls"),
      "[DONE]"
    )
    third = sse_body(content_chunk("Both rounds are audited."), finish_chunk("stop"), "[DONE]")
    stub_openai_stream(first, second, third)

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @assistant.respond_to(@message)
    end

    assert_nil @chat.reload.error
    owner = @chat.messages.where(type: "AssistantMessage").sole
    assert_equal "Both rounds are audited.", owner.content

    audits = owner.tool_calls.order(:id)
    assert_equal %w[1:0 2:0], audits.map(&:provider_id)
    assert_equal %w[call_repeated call_repeated], audits.map(&:provider_call_id)
    # RubyLLM treats an id answered in an earlier round as already answered, so
    # the repeated second call is audited but never dispatched. Its distinct
    # round-local identity and closed outcome prove the audit does not collide.
    assert_includes audits.first.function_result.fetch("accounts").map { |entry| entry["name"] }, account.name
    assert_equal "Tool call was not executed.", audits.last.function_result.fetch("error")
    assert_requested :post, OPENAI_CHAT_URL, times: 3
  end

  test "records an interrupted outcome when a tool executes but its result is never audited" do
    create_family_account("Bound family checking", 5123.45)

    stub_live_catalog_admission
    stub_openai_stream(
      sse_body(
        tool_call_chunk([ { id: "call_interrupted", name: "get_accounts", arguments: "{}" } ]),
        finish_chunk("tool_calls"),
        "[DONE]"
      )
    )

    Provider::RubyLlm::FinancialTool::GetAccounts.any_instance
      .expects(:call).once.raises(StandardError, "tool executed then failed before result recording")

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @assistant.respond_to(@message)
    end

    assert_requested :post, OPENAI_CHAT_URL, times: 1

    owner = @chat.messages.where(type: "AssistantMessage").sole
    assert_equal "failed", owner.status
    assert_equal "", owner.content
    refute_includes @chat.conversation_messages, owner

    audit = owner.tool_calls.sole
    outcome = audit.function_result.fetch("error")
    assert_match(/outcome is unknown|interrupted/i, outcome)
    refute_match(/was not executed/i, outcome)
    assert @chat.reload.error.present?
    assert_predicate @chat.reload, :needs_assistant_response?
  end

  test "redacts tool-call audit arguments and results from SQL and inspection logs while retaining them in the database" do
    args_marker = "SYNTHETIC-SQL-ARGUMENT-MARKER"
    create_result_marker = "SYNTHETIC-SQL-RESULT-MARKER"
    update_result_marker = "SYNTHETIC-SQL-UPDATE-MARKER"

    output = StringIO.new
    original_logger = ActiveRecord::Base.logger
    ActiveRecord::Base.logger = Logger.new(output)
    ActiveRecord::Base.logger.level = Logger::DEBUG

    begin
      audit = ToolCall::Function.create!(
        message: @message,
        provider_id: "log:1",
        provider_call_id: "log_call",
        function_name: "get_accounts",
        function_arguments: { "marker" => args_marker },
        function_result: { "marker" => create_result_marker }
      )
      audit.update!(function_result: { "marker" => update_result_marker })
    ensure
      ActiveRecord::Base.logger = original_logger
    end

    log = output.string
    assert_includes log, "INSERT INTO \"tool_calls\""
    assert_includes log, "UPDATE \"tool_calls\""
    refute_includes log, args_marker
    refute_includes log, create_result_marker
    refute_includes log, update_result_marker
    assert_includes log, "[FILTERED]"

    audit.reload
    assert_equal({ "marker" => args_marker }, audit.function_arguments)
    assert_equal({ "marker" => update_result_marker }, audit.function_result)

    refute_includes audit.inspect, args_marker
    refute_includes audit.inspect, update_result_marker
  end

  private
    def header_value(request, name)
      request.headers.find { |header, _value| header.to_s.casecmp?(name) }&.last
    end

    def stub_openai_stream(*responses)
      stubbed = responses.map do |response|
        if response.is_a?(Hash)
          response
        else
          { status: 200, headers: { "Content-Type" => "text/event-stream" }, body: response }
        end
      end

      stub_request(:post, OPENAI_CHAT_URL)
        .with(headers: { "Authorization" => "Bearer test-openai-key" })
        .to_return(*stubbed)
    end

    def sse_body(*events)
      events.map do |event|
        event == "[DONE]" ? "data: [DONE]\n\n" : "data: #{event.to_json}\n\n"
      end.join
    end

    def tool_call_chunk(calls)
      tool_calls = calls.each_with_index.map do |call, index|
        {
          "index" => index,
          "id" => call[:id],
          "type" => "function",
          "function" => { "name" => call[:name], "arguments" => call.fetch(:arguments) }
        }.compact
      end

      {
        "id" => "chatcmpl-tool-#{SecureRandom.hex(4)}",
        "object" => "chat.completion.chunk",
        "choices" => [ { "index" => 0, "delta" => { "tool_calls" => tool_calls }, "finish_reason" => nil } ]
      }
    end

    def raw_tool_call_chunk(tool_calls)
      {
        "id" => "chatcmpl-raw-tool-#{SecureRandom.hex(4)}",
        "object" => "chat.completion.chunk",
        "choices" => [ { "index" => 0, "delta" => { "tool_calls" => tool_calls }, "finish_reason" => nil } ]
      }
    end

    def content_chunk(text)
      {
        "id" => "chatcmpl-content-#{SecureRandom.hex(4)}",
        "object" => "chat.completion.chunk",
        "choices" => [ { "index" => 0, "delta" => { "content" => text }, "finish_reason" => nil } ]
      }
    end

    def finish_chunk(reason)
      {
        "id" => "chatcmpl-finish-#{SecureRandom.hex(4)}",
        "object" => "chat.completion.chunk",
        "choices" => [ { "index" => 0, "delta" => {}, "finish_reason" => reason } ]
      }
    end

    def create_family_account(name, balance)
      @chat.user.family.accounts.create!(
        name: name,
        balance: balance,
        currency: "USD",
        accountable: Depository.new
      )
    end

    def create_other_family_account(name, balance)
      family = Family.create!(name: "Other family #{SecureRandom.hex(4)}")
      family.accounts.create!(
        name: name,
        balance: balance,
        currency: "USD",
        accountable: Depository.new
      )
    end

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
