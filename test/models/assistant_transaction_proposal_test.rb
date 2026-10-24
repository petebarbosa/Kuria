require "test_helper"

class AssistantTransactionProposalTest < ActiveSupport::TestCase
  OPENAI_CHAT_URL = Provider::RubyLlm::OPENAI_BASE_URL + "/chat/completions"

  setup do
    @chat = chats(:two)
    @user = @chat.user
    @family = @user.family
    @account = @family.accounts.create!(
      name: "Proposal checking",
      balance: 1000,
      currency: "USD",
      accountable: Depository.new
    )
    @message = @chat.messages.create!(
      type: "UserMessage",
      content: "Please propose a coffee purchase.",
      ai_model: "openai/gpt-4o"
    )
    @assistant = Assistant.for_chat(@chat)
    stub_live_catalog_admission
  end

  test "prepares one user and family bound proposal, audits it, and never mutates financial data" do
    stub_openai_stream(
      sse_body(
        tool_call_chunk([ propose_call(id: "call_proposal", arguments: proposal_arguments) ]),
        finish_chunk("tool_calls"),
        "[DONE]"
      ),
      sse_body(content_chunk("I prepared the transaction for your review."), finish_chunk("stop"), "[DONE]")
    )

    assert_no_difference([ "Entry.count", "Transaction.count" ]) do
      assert_difference("PendingAction.count", 1) do
        with_env_overrides OPENAI_API_KEY: "test-openai-key" do
          @assistant.respond_to(@message)
        end
      end
    end

    pending = PendingAction.find_by!(action_type: "create_transaction")
    assert_equal @family.id, pending.family_id
    assert_equal @user.id, pending.user_id
    assert_nil @chat.reload.error

    owner = assistant_messages.sole
    assert_equal "I prepared the transaction for your review.", owner.content
    audit = owner.tool_calls.sole
    assert_equal "1:0", audit.provider_id
    assert_equal "call_proposal", audit.provider_call_id
    assert_equal "propose_transaction", audit.function_name
    assert_equal proposal_arguments.stringify_keys, audit.function_arguments
    assert_equal "pending_confirmation", audit.function_result.fetch("status")
    assert_equal pending.id, audit.function_result.fetch("pending_action_id")

    assert_requested(:post, OPENAI_CHAT_URL, times: 2) do |request|
      proposal_tool = parsed_tools(request).find { |tool| tool.dig("function", "name") == "propose_transaction" }
      next false if proposal_tool.nil?

      properties = proposal_tool.dig("function", "parameters", "properties").keys
      !properties.include?("family_id") &&
        !properties.include?("user_id") &&
        !properties.include?("idempotency_key")
    end
  end

  test "a retried provider call reuses the pending proposal instead of creating a duplicate" do
    call = propose_call(id: "call_proposal", arguments: proposal_arguments)

    stub_openai_stream(
      sse_body(tool_call_chunk([ call ]), finish_chunk("tool_calls"), "[DONE]"),
      sse_body(content_chunk("First proposal prepared."), finish_chunk("stop"), "[DONE]"),
      sse_body(tool_call_chunk([ call ]), finish_chunk("tool_calls"), "[DONE]"),
      sse_body(content_chunk("The same proposal is still pending."), finish_chunk("stop"), "[DONE]")
    )

    assert_no_difference([ "Entry.count", "Transaction.count" ]) do
      assert_difference("PendingAction.count", 1) do
        with_env_overrides OPENAI_API_KEY: "test-openai-key" do
          @assistant.respond_to(@message)
        end
      end

      assert_no_difference("PendingAction.count") do
        with_env_overrides OPENAI_API_KEY: "test-openai-key" do
          @assistant.respond_to(@message)
        end
      end
    end

    pending = PendingAction.find_by!(action_type: "create_transaction")
    assert_equal 1, PendingAction.where(action_type: "create_transaction").count
    assert_equal 2, assistant_messages.count
    assert_equal [ pending.id ], assistant_messages.order(:created_at).map { |message| message.tool_calls.sole.function_result.fetch("pending_action_id") }.uniq
    assert_requested :post, OPENAI_CHAT_URL, times: 4
  end

  test "rejects model supplied scope metadata and audits the rejection" do
    malicious_arguments = proposal_arguments.merge("family_id" => Family.create!(name: "Other family").id)

    stub_openai_stream(
      sse_body(
        tool_call_chunk([ propose_call(id: "call_scope", arguments: malicious_arguments) ]),
        finish_chunk("tool_calls"),
        "[DONE]"
      ),
      sse_body(content_chunk("I cannot select a family or user."), finish_chunk("stop"), "[DONE]")
    )

    assert_no_difference([ "PendingAction.count", "Entry.count", "Transaction.count" ]) do
      with_env_overrides OPENAI_API_KEY: "test-openai-key" do
        @assistant.respond_to(@message)
      end
    end

    audit = assistant_messages.sole.tool_calls.sole
    assert_equal malicious_arguments.stringify_keys, audit.function_arguments
    assert_equal Provider::RubyLlm::FinancialTool::ProposeTransaction::AUTHORIZATION_ERROR,
      audit.function_result.fetch("error")
  end

  test "rejects references from another family and audits the rejection" do
    other_family = Family.create!(name: "Other proposal family")
    other_account = other_family.accounts.create!(
      name: "Other family account",
      balance: 500,
      currency: "USD",
      accountable: Depository.new
    )
    arguments = proposal_arguments.merge("account_id" => other_account.id)

    stub_openai_stream(
      sse_body(
        tool_call_chunk([ propose_call(id: "call_foreign", arguments: arguments) ]),
        finish_chunk("tool_calls"),
        "[DONE]"
      ),
      sse_body(content_chunk("That account is not available."), finish_chunk("stop"), "[DONE]")
    )

    assert_no_difference([ "PendingAction.count", "Entry.count", "Transaction.count" ]) do
      with_env_overrides OPENAI_API_KEY: "test-openai-key" do
        @assistant.respond_to(@message)
      end
    end

    audit = assistant_messages.sole.tool_calls.sole
    assert_equal other_account.id, audit.function_arguments.fetch("account_id")
    assert_equal Provider::RubyLlm::FinancialTool::ProposeTransaction::REFERENCE_ERROR,
      audit.function_result.fetch("error")
  end

  private
    def proposal_arguments
      {
        "account_id" => @account.id,
        "date" => Date.current.to_s,
        "name" => "Coffee",
        "amount" => "4.50"
      }
    end

    def propose_call(id:, arguments:)
      { id: id, name: "propose_transaction", arguments: arguments.to_json }
    end

    def assistant_messages
      @chat.messages.where(type: "AssistantMessage")
    end

    def parsed_tools(request)
      JSON.parse(request.body).fetch("tools", [])
    end

    def stub_live_catalog_admission
      Provider::RubyLlm::Catalog.any_instance.stubs(:available?).returns(true)
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
end
