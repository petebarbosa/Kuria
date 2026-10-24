require "test_helper"

# Public-boundary coverage for #12 phase 2: the Assistant reconstructs a
# provider-neutral history snapshot from persisted records, and RubyLLM sends
# it on the actual Chat Completions request. No live provider is contacted.
class AssistantHistoryTest < ActiveSupport::TestCase
  CHAT_URL = Provider::RubyLlm::OPENAI_BASE_URL + "/chat/completions"
  MODEL = "openai/gpt-5-nano"
  API_KEY = "test-openai-key"
  BASE_TIME = Time.zone.parse("2026-01-01 12:00:00")

  setup do
    @chat = Chat.create!(user: users(:family_admin), title: "History #{SecureRandom.hex(4)}")
    Provider::RubyLlm::Catalog.any_instance.stubs(:available?).returns(true)
  end

  test "three turns send accumulated persisted facts and condition the third answer on the HTTP body" do
    bodies = []
    stub_request(:post, CHAT_URL)
      .with(headers: { "Authorization" => "Bearer #{API_KEY}" })
      .to_return do |request|
        body = JSON.parse(request.body)
        bodies << body
        messages = body.fetch("messages")
        last_user = messages.reverse.find { |message| message["role"] == "user" }.fetch("content")

        answer = case last_user
        when "First question ALPHA"
          "First answer retains ALPHA"
        when "Second question BETA"
          "Second answer retains ALPHA and BETA"
        else
          remembered = messages.select { |message| message["role"] == "assistant" }
            .map { |message| message["content"].to_s }
            .join(" ")

          remembered.include?("ALPHA") && remembered.include?("BETA") ? "THIRD-OK" : "THIRD-MISSING-HISTORY"
        end

        {
          status: 200,
          headers: { "Content-Type" => "text/event-stream" },
          body: answer_body(answer)
        }
      end

    first = create_user_message("First question ALPHA", at: BASE_TIME)
    respond(first, assistant: Assistant.for_chat(@chat))
    set_last_assistant_time(BASE_TIME + 30.seconds)

    second = create_user_message("Second question BETA", at: BASE_TIME + 1.minute)
    respond(second, assistant: Assistant.for_chat(@chat))
    set_last_assistant_time(BASE_TIME + 1.minute + 30.seconds)

    third = create_user_message("Third question", at: BASE_TIME + 2.minutes)
    respond(third, assistant: Assistant.for_chat(@chat))

    assert_equal 3, bodies.size
    assert_equal [ "First question ALPHA" ], user_contents(bodies.first)
    assert_equal [ "First question ALPHA", "Second question BETA" ], user_contents(bodies.second)
    assert_equal [ "First question ALPHA", "Second question BETA", "Third question" ], user_contents(bodies.third)

    third_messages = bodies.third.fetch("messages")
    assert_equal 1, third_messages.count { |message| message["content"] == "Third question" }
    assert_includes third_messages.map { |message| message["content"] }, "First answer retains ALPHA"
    assert_includes third_messages.map { |message| message["content"] }, "Second answer retains ALPHA and BETA"

    assert_equal "THIRD-OK", @chat.messages.where(type: "AssistantMessage").order(:id).last.content
    assert_nil @chat.reload.error
  end

  test "replays non-debug Developer messages as system while skipping only the exact current guardrails" do
    assistant = Assistant.for_chat(@chat)
    guardrails = assistant.instructions

    create_user_message("EARLIER-USER", at: BASE_TIME)
    create_assistant_message("EARLIER-ANSWER", at: BASE_TIME + 1.minute)
    create_developer_message(guardrails, at: BASE_TIME + 2.minutes)
    create_developer_message("INTENTIONAL-REPEAT", at: BASE_TIME + 3.minutes)
    create_developer_message("INTENTIONAL-REPEAT", at: BASE_TIME + 4.minutes)
    create_developer_message("DEBUG-DEVELOPER-HIDDEN", at: BASE_TIME + 5.minutes, debug: true)
    target = create_user_message("CURRENT-QUESTION", at: BASE_TIME + 6.minutes)

    bodies = stub_capturing_chat(answer_body("OK"))
    respond(target, assistant: assistant)

    messages = bodies.sole.fetch("messages")
    developer_contents = messages.select { |message| message["role"] == "developer" }
      .map { |message| message["content"] }

    assert_equal 1, developer_contents.count(guardrails)
    assert_equal 2, developer_contents.count("INTENTIONAL-REPEAT")
    refute_includes developer_contents, "DEBUG-DEVELOPER-HIDDEN"
    assert_equal [ guardrails, "INTENTIONAL-REPEAT", "INTENTIONAL-REPEAT" ], developer_contents

    non_developer_roles = messages.reject { |message| message["role"] == "developer" }
      .map { |message| message["role"] }
    assert_equal %w[user assistant user], non_developer_roles
    assert_equal 1, messages.count { |message| message["role"] == "user" && message["content"] == "CURRENT-QUESTION" }
  end

  test "excludes reasoning, pending, and failed assistants and their tool audits" do
    McpTools::GetAccounts.expects(:call).never

    create_user_message("EARLIER-USER", at: BASE_TIME)
    create_assistant_message("NORMAL-ANSWER", at: BASE_TIME + 1.minute)
    create_assistant_message("REASONING-HIDDEN", at: BASE_TIME + 2.minutes, reasoning: true)
    pending_owner = create_assistant_message("PENDING-HIDDEN", at: BASE_TIME + 3.minutes, status: :pending)
    failed_owner = create_assistant_message("FAILED-HIDDEN", at: BASE_TIME + 4.minutes, status: :failed)

    create_tool_call(
      pending_owner,
      provider_id: "not-a-round",
      provider_call_id: "pending-call",
      arguments: "not-a-hash",
      result: { "status" => "pending" }
    )
    create_tool_call(
      failed_owner,
      provider_id: "1:0",
      provider_call_id: "failed-call",
      arguments: {},
      result: { "error" => "Tool result too large to audit." }
    )

    target = create_user_message("CURRENT-QUESTION", at: BASE_TIME + 5.minutes)

    bodies = stub_capturing_chat(answer_body("OK"))
    respond(target)

    messages = bodies.sole.fetch("messages")
    contents = messages.map { |message| message["content"].to_s }

    assert_includes contents, "NORMAL-ANSWER"
    refute_includes contents, "REASONING-HIDDEN"
    refute_includes contents, "PENDING-HIDDEN"
    refute_includes contents, "FAILED-HIDDEN"
    refute_includes contents, "pending-call"
    refute_includes contents, "failed-call"
    assert_equal 1, messages.count { |message| message["role"] == "assistant" }
    assert_nil @chat.reload.error
  end

  test "uses a strict created_at/id boundary and excludes the current and later messages" do
    tie = BASE_TIME
    create_user_message("EARLIER-TIED", at: tie)
    target = create_user_message("CURRENT-TARGET", at: tie)
    create_user_message("LATER-TIED", at: tie)
    create_assistant_message("LATER-ANSWER", at: tie + 1.second)

    bodies = stub_capturing_chat(answer_body("OK"))
    ask_through_chat(target)

    messages = bodies.sole.fetch("messages")
    contents = messages.map { |message| message["content"].to_s }

    assert_includes contents, "EARLIER-TIED"
    assert_equal 1, contents.count("CURRENT-TARGET")
    refute_includes contents, "LATER-TIED"
    refute_includes contents, "LATER-ANSWER"
  end

  test "reconstructs completed tool rounds in numeric order with history-only ids and no new audits" do
    McpTools::GetAccounts.expects(:call).never

    create_user_message("HISTORY-TOOL-QUESTION", at: BASE_TIME)
    owner = create_assistant_message("HISTORICAL-FINAL-ANSWER", at: BASE_TIME + 1.second)

    # Create out of insertion/created_at order: numeric round/index must win.
    round_two = create_tool_call(
      owner,
      provider_id: "2:0",
      provider_call_id: "call-repeat",
      result: { "error" => "Tool call was not executed." },
      at: BASE_TIME + 4.seconds
    )
    round_one_index_one = create_tool_call(
      owner,
      provider_id: "1:1",
      provider_call_id: "call-other",
      result: { "error" => "Account access is restricted to the authenticated family." },
      at: BASE_TIME + 2.seconds
    )
    round_one_index_zero = create_tool_call(
      owner,
      provider_id: "1:0",
      provider_call_id: "call-repeat",
      result: { "accounts" => [ { "name" => "HISTORY-ACCOUNT-ONE" } ] },
      at: BASE_TIME + 3.seconds
    )
    target = create_user_message("CURRENT-QUESTION", at: BASE_TIME + 5.seconds)

    before_audit_count = ToolCall.count
    bodies = stub_capturing_chat(answer_body("OK"))
    respond(target)

    assert_equal before_audit_count, ToolCall.count
    assert_requested :post, CHAT_URL, times: 1

    messages = bodies.sole.fetch("messages")
    tool_requests = messages.select { |message| message["role"] == "assistant" && message["tool_calls"].present? }

    expected_ids = [
      [ history_tool_call_id(round_one_index_zero), history_tool_call_id(round_one_index_one) ],
      [ history_tool_call_id(round_two) ]
    ]
    assert_equal expected_ids, tool_requests.map { |request| request.fetch("tool_calls").map { |call| call.fetch("id") } }
    assert tool_requests.all? { |request| request.fetch("content") == "" }

    tool_results = messages.select { |message| message["role"] == "tool" }
    assert_equal expected_ids.flatten, tool_results.map { |message| message.fetch("tool_call_id") }
    assert_equal %w[developer user assistant tool tool assistant tool assistant user],
      messages.map { |message| message["role"] }
    assert_equal "HISTORY-ACCOUNT-ONE",
      JSON.parse(tool_results.first.fetch("content")).dig("accounts", 0, "name")
    assert_includes tool_results.second.fetch("content"), "Account access is restricted"
    assert_includes tool_results.third.fetch("content"), "Tool call was not executed"

    final_answers = messages.select { |message| message["role"] == "assistant" && message["tool_calls"].blank? }
    assert_equal [ "HISTORICAL-FINAL-ANSWER" ], final_answers.map { |message| message.fetch("content") }

    assert_equal "call-repeat", round_one_index_zero.reload.provider_call_id
    assert_equal "call-repeat", round_two.reload.provider_call_id
    assert_equal "call-other", round_one_index_one.reload.provider_call_id
  end

  test "a new live tool call reusing a historical provider call id still executes" do
    account = create_family_account("Live collision checking", 123.45)

    create_user_message("HISTORY-QUESTION", at: BASE_TIME)
    owner = create_assistant_message("HISTORY-ANSWER", at: BASE_TIME + 1.second)
    historical_audit = create_tool_call(
      owner,
      provider_id: "1:0",
      provider_call_id: "call_repeated",
      result: { "accounts" => [ { "name" => "HISTORICAL-ACCOUNT" } ] },
      at: BASE_TIME + 2.seconds
    )
    target = create_user_message("CURRENT-QUESTION", at: BASE_TIME + 3.seconds)

    bodies = stub_capturing_chat(
      sse_body(
        tool_call_chunk([ { id: "call_repeated", name: "get_accounts", arguments: "{}" } ]),
        finish_chunk("tool_calls"),
        "[DONE]"
      ),
      answer_body("LIVE-TOOL-COMPLETED")
    )

    respond(target)

    assert_nil @chat.reload.error
    assert_requested :post, CHAT_URL, times: 2
    assert_equal 2, bodies.size

    live_owner = @chat.messages.where(type: "AssistantMessage").order(:id).last
    assert_equal "LIVE-TOOL-COMPLETED", live_owner.content
    live_audit = live_owner.tool_calls.sole
    assert_equal "call_repeated", live_audit.provider_call_id
    assert_equal "1:0", live_audit.provider_id
    assert_includes live_audit.function_result.fetch("accounts").map { |entry| entry["name"] }, account.name

    historical_request = bodies.first.fetch("messages").find do |message|
      message["role"] == "assistant" && message["tool_calls"].present?
    end
    historical_call_id = historical_request.fetch("tool_calls").sole.fetch("id")
    assert_match(/\Ahistory-tool-call-\d+\z/, historical_call_id)
    refute_equal "call_repeated", historical_call_id

    live_tool_message = bodies.second.fetch("messages").find do |message|
      message["role"] == "tool" && message["tool_call_id"] == "call_repeated"
    end
    assert live_tool_message, "the live tool round must answer the original provider call id"
    assert_includes live_tool_message.fetch("content"), account.name

    assert_equal "call_repeated", historical_audit.reload.provider_call_id
  end

  test "fails closed without a provider request or phantom owner for unsafe completed tool audits" do
    cases = {
      invalid_round_identifier: ->(owner) {
        create_tool_call(owner, provider_id: "legacy", provider_call_id: "call-1")
      },
      duplicate_round_index: ->(owner) {
        create_tool_call(owner, provider_id: "1:0", provider_call_id: "call-1")
        create_tool_call(owner, provider_id: "1:0", provider_call_id: "call-2")
      },
      non_contiguous_rounds: ->(owner) {
        create_tool_call(owner, provider_id: "2:0", provider_call_id: "call-1")
      },
      index_gap: ->(owner) {
        create_tool_call(owner, provider_id: "1:0", provider_call_id: "call-1")
        create_tool_call(owner, provider_id: "1:2", provider_call_id: "call-2")
      },
      missing_provider_call_id: ->(owner) {
        create_tool_call(owner, provider_id: "1:0", provider_call_id: nil)
      },
      missing_function_name: ->(owner) {
        call = create_tool_call(owner, provider_id: "1:0")
        call.update_column(:function_name, nil)
      },
      non_hash_arguments: ->(owner) {
        create_tool_call(owner, provider_id: "1:0", arguments: "not-a-hash")
      },
      pending_result: ->(owner) {
        create_tool_call(owner, provider_id: "1:0", result: { "status" => "pending" })
      },
      overflow_result: ->(owner) {
        create_tool_call(owner, provider_id: "1:0", result: { "error" => "Tool result too large to audit." })
      },
      interrupted_result: ->(owner) {
        create_tool_call(owner, provider_id: "1:0",
          result: { "error" => "Tool execution outcome is unknown because the response was interrupted." })
      },
      missing_result: ->(owner) {
        call = create_tool_call(owner, provider_id: "1:0")
        call.update_column(:function_result, nil)
      },
      non_hash_result: ->(owner) {
        call = create_tool_call(owner, provider_id: "1:0")
        call.update_column(:function_result, [ "not-a-hash" ])
      }
    }

    cases.each do |label, prepare|
      chat = Chat.create!(user: users(:family_admin), title: "Unsafe history #{label}")
      create_user_message("UNSAFE-HISTORY-USER", at: BASE_TIME, chat: chat)
      owner = create_assistant_message("UNSAFE-OWNER-ANSWER", at: BASE_TIME + 1.second, chat: chat)
      prepare.call(owner)
      target = create_user_message("CURRENT-#{label}", at: BASE_TIME + 2.seconds, chat: chat)

      snapshot = chat.messages.order(:id).map { |message| [ message.id, message.content, message.status ] }
      captured_error = nil
      chat.define_singleton_method(:add_error) { |error| captured_error = error }

      stub_chat_stream(answer_body("SHOULD-NOT-BE-USED"))
      streams = capture_turbo_stream_broadcasts(chat) do
        with_env_overrides OPENAI_API_KEY: "test-openai-key" do
          Assistant.for_chat(chat).respond_to(target)
        end
      end

      assert_not_requested :post, CHAT_URL
      assert_instance_of Assistant::HistoryReconstructionError, captured_error, label.to_s
      assert_equal Assistant::HISTORY_RECONSTRUCTION_ERROR_MESSAGE, captured_error.message, label.to_s
      assert_nil captured_error.details, label.to_s
      assert_equal snapshot, chat.messages.order(:id).map { |message| [ message.id, message.content, message.status ] },
        "#{label} must not touch persisted historical messages"
      assert_equal 1, streams.count { |stream| stream["action"] == "remove" && stream["target"] == "thinking-indicator" },
        "#{label} must stop the thinking indicator exactly once"
      assert_equal 0, chat.messages.where(type: "AssistantMessage", status: %w[pending failed]).count,
        "#{label} must not leave a phantom attempt owner"
    end
  end

  test "never includes messages from another chat or family" do
    other_family_chat = Chat.create!(user: users(:empty), title: "Other family")
    create_user_message("OTHER-FAMILY-USER", at: BASE_TIME, chat: other_family_chat)
    create_assistant_message("OTHER-FAMILY-ANSWER", at: BASE_TIME + 1.second, chat: other_family_chat)

    other_chat_same_user = Chat.create!(user: @chat.user, title: "Other chat")
    create_user_message("OTHER-CHAT-USER", at: BASE_TIME, chat: other_chat_same_user)
    create_assistant_message("OTHER-CHAT-ANSWER", at: BASE_TIME + 1.second, chat: other_chat_same_user)

    create_user_message("HOME-USER", at: BASE_TIME + 2.seconds)
    create_assistant_message("HOME-ANSWER", at: BASE_TIME + 3.seconds)
    target = create_user_message("CURRENT-QUESTION", at: BASE_TIME + 4.seconds)

    bodies = stub_capturing_chat(answer_body("OK"))
    respond(target)

    contents = bodies.sole.fetch("messages").map { |message| message["content"].to_s }

    assert_includes contents, "HOME-USER"
    assert_includes contents, "HOME-ANSWER"
    refute_includes contents, "OTHER-FAMILY-USER"
    refute_includes contents, "OTHER-FAMILY-ANSWER"
    refute_includes contents, "OTHER-CHAT-USER"
    refute_includes contents, "OTHER-CHAT-ANSWER"
  end

  private
    def respond(message, assistant: Assistant.for_chat(@chat))
      with_env_overrides OPENAI_API_KEY: "test-openai-key" do
        assistant.respond_to(message)
      end
    end

    def ask_through_chat(message)
      with_env_overrides OPENAI_API_KEY: "test-openai-key" do
        @chat.ask_assistant(message)
      end
    end

    def create_user_message(content, at:, chat: @chat)
      chat.messages.create!(
        type: "UserMessage",
        content: content,
        ai_model: MODEL,
        created_at: at
      )
    end

    def create_assistant_message(content, at:, chat: @chat, status: :complete, reasoning: false)
      chat.messages.create!(
        type: "AssistantMessage",
        content: content,
        ai_model: MODEL,
        status: status,
        reasoning: reasoning,
        created_at: at
      )
    end

    def create_developer_message(content, at:, chat: @chat, debug: false)
      chat.messages.create!(
        type: "DeveloperMessage",
        content: content,
        debug: debug,
        created_at: at
      )
    end

    def create_tool_call(owner, provider_id:, provider_call_id: "call-1", name: "get_accounts",
      arguments: {}, result: { "accounts" => [] }, at: owner.created_at + 1.second)
      ToolCall::Function.create!(
        message: owner,
        provider_id: provider_id,
        provider_call_id: provider_call_id,
        function_name: name,
        function_arguments: arguments,
        function_result: result,
        created_at: at
      )
    end

    # Tests create assistant rows in real time while pinning user rows to
    # synthetic chronological timestamps; align the persisted answer with the
    # intended conversation order.
    def set_last_assistant_time(at)
      @chat.messages.where(type: "AssistantMessage").order(:id).last.update_column(:created_at, at)
    end

    def history_tool_call_id(tool_call)
      "history-tool-call-#{tool_call.id}"
    end

    def create_family_account(name, balance)
      @chat.user.family.accounts.create!(
        name: name,
        balance: balance,
        currency: "USD",
        accountable: Depository.new
      )
    end

    def user_contents(body)
      body.fetch("messages")
        .select { |message| message["role"] == "user" }
        .map { |message| message["content"] }
    end

    def stub_capturing_chat(*responses)
      bodies = []
      stub_request(:post, CHAT_URL)
        .with(headers: { "Authorization" => "Bearer #{API_KEY}" })
        .to_return do |request|
          bodies << JSON.parse(request.body)
          {
            status: 200,
            headers: { "Content-Type" => "text/event-stream" },
            body: responses.shift || answer_body("No response")
          }
        end
      bodies
    end

    def stub_chat_stream(body)
      stub_request(:post, CHAT_URL)
        .with(headers: { "Authorization" => "Bearer #{API_KEY}" })
        .to_return(status: 200, headers: { "Content-Type" => "text/event-stream" }, body: body)
    end

    def answer_body(text)
      sse_body(content_chunk(text), finish_chunk("stop"), "[DONE]")
    end

    def sse_body(*events)
      events.map do |event|
        event == "[DONE]" ? "data: [DONE]\n\n" : "data: #{event.to_json}\n\n"
      end.join
    end

    def content_chunk(text)
      {
        "id" => "chatcmpl-content-#{SecureRandom.hex(4)}",
        "object" => "chat.completion.chunk",
        "choices" => [ { "index" => 0, "delta" => { "content" => text }, "finish_reason" => nil } ]
      }
    end

    def tool_call_chunk(calls)
      tool_calls = calls.each_with_index.map do |call, index|
        {
          "index" => index,
          "id" => call.fetch(:id),
          "type" => "function",
          "function" => { "name" => call.fetch(:name), "arguments" => call.fetch(:arguments) }
        }
      end

      {
        "id" => "chatcmpl-tool-#{SecureRandom.hex(4)}",
        "object" => "chat.completion.chunk",
        "choices" => [ { "index" => 0, "delta" => { "tool_calls" => tool_calls }, "finish_reason" => nil } ]
      }
    end

    def finish_chunk(reason)
      {
        "id" => "chatcmpl-finish-#{SecureRandom.hex(4)}",
        "object" => "chat.completion.chunk",
        "choices" => [ { "index" => 0, "delta" => {}, "finish_reason" => reason } ]
      }
    end
end
