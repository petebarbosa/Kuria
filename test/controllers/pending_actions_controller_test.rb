require "test_helper"

class PendingActionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @account = @family.accounts.create!(
      name: "Pending controller account",
      balance: 1000,
      currency: "USD",
      accountable: Depository.new
    )
    @pending = PendingAction.create_pending!(
      action_type: "create_transaction",
      params: {
        "account_id" => @account.id,
        "date" => Date.current.to_s,
        "name" => "Controller proposal",
        "amount" => "12.34"
      },
      preview: { action: "create_transaction" },
      family: @family,
      user: @user
    )
    @audit = ToolCall::Function.create!(
      message: messages(:chat1_assistant_response),
      provider_id: "1:0",
      provider_call_id: "call_proposal",
      function_name: "propose_transaction",
      function_arguments: { "amount" => "12.34" },
      function_result: { "status" => "pending_confirmation", "pending_action_id" => @pending.id }
    )
    sign_in @user
  end

  test "confirms a pending action as the authenticated user" do
    assert_difference("Entry.count", 1) do
      post "/pending_actions/#{@pending.id}/confirm"
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "confirmed", body["status"]
    assert_equal "succeeded", body["execution_status"]
    assert_equal @pending.id, body["pending_action_id"]
    assert_equal true, body.dig("audit_result", "success")
    assert_equal "confirmed", body.dig("audit_result", "confirmation", "status")
    assert_equal @user.id, body.dig("audit_result", "confirmation", "confirmed_by")

    @pending.reload
    assert @pending.confirmed?
    assert_equal @user.id, @pending.confirmed_by
    refute_equal "mcp", @pending.confirmed_by

    @audit.reload
    assert_equal "confirmed", @audit.function_result.dig("confirmation", "status")
    assert_equal @user.id, @audit.function_result.dig("confirmation", "confirmed_by")
  end

  test "rejects a replayed confirmation without executing again" do
    post "/pending_actions/#{@pending.id}/confirm"
    assert_response :success

    assert_no_difference([ "Entry.count", "Transaction.count" ]) do
      post "/pending_actions/#{@pending.id}/confirm"
    end

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "rejected", body["status"]
    assert_equal "already_confirmed", body["reason"]
    assert_equal "succeeded", body["execution_status"]
  end

  test "returns the preserved succeeded status for a legacy successful replay" do
    @pending.update!(
      confirmed_at: 1.minute.ago,
      confirmed_by: @user.id,
      audit_result: { "success" => true, "entry_id" => 123 }
    )

    assert_no_difference([ "Entry.count", "Transaction.count" ]) do
      post "/pending_actions/#{@pending.id}/confirm"
    end

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "rejected", body["status"]
    assert_equal "already_confirmed", body["reason"]
    assert_equal "succeeded", body["execution_status"]

    @audit.reload
    assert_equal "succeeded", @audit.function_result["execution_status"]
  end

  test "returns the preserved failed status for a legacy failed replay" do
    @pending.update!(
      confirmed_at: 1.minute.ago,
      confirmed_by: @user.id,
      audit_result: { "success" => false, "error" => "legacy failure" }
    )

    post "/pending_actions/#{@pending.id}/confirm"

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "rejected", body["status"]
    assert_equal "failed", body["execution_status"]

    @audit.reload
    assert_equal "failed", @audit.function_result["execution_status"]
  end

  test "leaves an unknown legacy execution status unknown on replay" do
    @pending.update!(
      confirmed_at: 1.minute.ago,
      confirmed_by: @user.id,
      audit_result: { "legacy_marker" => true }
    )

    post "/pending_actions/#{@pending.id}/confirm"

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "rejected", body["status"]
    assert_nil body["execution_status"]

    @audit.reload
    assert_nil @audit.function_result["execution_status"]
  end

  test "returns unprocessable entity when execution fails and reports both audits" do
    @pending.update!(params: @pending.params.merge("date" => "not-a-date"))

    assert_no_difference([ "Entry.count", "Transaction.count" ]) do
      post "/pending_actions/#{@pending.id}/confirm"
    end

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "confirmed", body["status"]
    assert_equal "failed", body["execution_status"]
    assert_equal false, body.dig("audit_result", "success")
    assert_equal "failed", body.dig("audit_result", "execution_status")
    assert_equal "confirmed", body.dig("audit_result", "confirmation", "status")

    @pending.reload
    assert @pending.confirmed?
    assert_equal false, @pending.audit_result["success"]
    assert_equal "failed", @pending.audit_result["execution_status"]

    @audit.reload
    assert_equal "failed", @audit.function_result["execution_status"]
    assert_equal "confirmed", @audit.function_result.dig("confirmation", "status")
  end

  test "reports a replay after a failed execution as rejected without retrying" do
    @pending.update!(params: @pending.params.merge("date" => "not-a-date"))

    post "/pending_actions/#{@pending.id}/confirm"
    assert_response :unprocessable_entity

    assert_no_difference([ "Entry.count", "Transaction.count" ]) do
      post "/pending_actions/#{@pending.id}/confirm"
    end

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "rejected", body["status"]
    assert_equal "already_confirmed", body["reason"]
    assert_equal "failed", body["execution_status"]
  end

  test "rejects an expired confirmation without executing" do
    @pending.update!(expires_at: 1.hour.ago)

    assert_no_difference([ "Entry.count", "Transaction.count" ]) do
      post "/pending_actions/#{@pending.id}/confirm"
    end

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "rejected", body["status"]
    assert_equal "expired", body["reason"]
    assert_nil @pending.reload.confirmed_at
  end

  test "rejects a user from another family without mutating the pending action" do
    sign_in users(:empty)

    assert_no_difference([ "Entry.count", "Transaction.count" ]) do
      post "/pending_actions/#{@pending.id}/confirm"
    end

    assert_response :not_found

    @pending.reload
    assert_nil @pending.confirmed_at
    assert_nil @pending.audit_result
  end
end

# End-to-end at the real proposal seam: a deterministic RubyLLM assistant turn
# persists the proposal, then an authenticated request confirms it and the
# financial mutation plus both audit trails are asserted.
class PendingActionProposalConfirmationTest < ActionDispatch::IntegrationTest
  OPENAI_CHAT_URL = Provider::RubyLlm::OPENAI_BASE_URL + "/chat/completions"

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @account = @family.accounts.create!(
      name: "E2E proposal account",
      balance: 1000,
      currency: "USD",
      accountable: Depository.new
    )
    @chat = Chat.create!(user: @user, title: "E2E proposal")
    @message = @chat.messages.create!(
      type: "UserMessage",
      content: "Please propose a coffee purchase.",
      ai_model: "openai/gpt-4o"
    )
    @assistant = Assistant.for_chat(@chat)
    Provider::RubyLlm::Catalog.any_instance.stubs(:available?).returns(true)
    sign_in @user
  end

  test "proposal confirmed through the authenticated endpoint mutates once and audits both sides" do
    stub_openai_stream(
      sse_body(
        tool_call_chunk([ propose_call(id: "call_e2e", arguments: proposal_arguments) ]),
        finish_chunk("tool_calls"),
        "[DONE]"
      ),
      sse_body(content_chunk("I prepared the transaction for your review."), finish_chunk("stop"), "[DONE]")
    )

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @assistant.respond_to(@message)
    end

    owner = @chat.messages.where(type: "AssistantMessage").sole
    audit = owner.tool_calls.sole
    pending_id = audit.function_result.fetch("pending_action_id")
    pending = PendingAction.find(pending_id)

    assert_equal "pending_confirmation", audit.function_result["status"]
    assert_equal @user.id, pending.user_id
    assert_equal @family.id, pending.family_id

    assert_difference([ "Entry.count", "Transaction.count" ], 1) do
      post "/pending_actions/#{pending_id}/confirm"
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "confirmed", body["status"]
    assert_equal "succeeded", body["execution_status"]

    pending.reload
    assert pending.confirmed?
    assert_equal @user.id, pending.confirmed_by
    assert_equal true, pending.audit_result["success"]
    assert_equal "succeeded", pending.audit_result["execution_status"]
    assert_equal @user.id, pending.audit_result.dig("confirmation", "confirmed_by")

    audit.reload
    assert_equal "confirmed", audit.function_result.dig("confirmation", "status")
    assert_equal "succeeded", audit.function_result["execution_status"]
    assert_equal @user.id, audit.function_result.dig("confirmation", "confirmed_by")

    entry = Entry.find(pending.audit_result["entry_id"])
    assert_equal "Coffee", entry.name
    assert_equal BigDecimal("4.50"), entry.amount
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
