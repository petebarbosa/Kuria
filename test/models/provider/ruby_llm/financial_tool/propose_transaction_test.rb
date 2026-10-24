require "test_helper"

class Provider::RubyLlm::FinancialTool::ProposeTransactionTest < ActiveSupport::TestCase
  setup do
    @chat = chats(:two)
    @user = @chat.user
    @family = @user.family
    @message = @chat.messages.create!(
      type: "UserMessage",
      content: "Please propose a transaction.",
      ai_model: "openai/gpt-4o"
    )
    @account = @family.accounts.create!(
      name: "Proposal account",
      balance: 1000,
      currency: "USD",
      accountable: Depository.new
    )
    @tool = build_tool
  end

  test "exposes only transaction fields and no server scope metadata" do
    schema = @tool.parameters_schema

    assert_equal "propose_transaction", @tool.name
    assert_equal(
      %w[account_id amount category_id currency date kind merchant_id name],
      schema.fetch("properties").keys.sort
    )
    assert_equal %w[account_id amount date name], schema.fetch("required").sort
    assert_equal false, schema.fetch("additionalProperties")

    refute_includes schema.fetch("properties").keys, "family_id"
    refute_includes schema.fetch("properties").keys, "user_id"
    refute_includes schema.fetch("properties").keys, "idempotency_key"
  end

  test "creates a family and user bound pending proposal without mutating financial data" do
    result = nil

    assert_no_difference([ "Entry.count", "Transaction.count" ]) do
      assert_difference("PendingAction.count", 1) do
        result = @tool.call(**valid_arguments)
      end
    end

    pending = PendingAction.find(result.fetch(:pending_action_id))
    assert_equal "pending_confirmation", result.fetch(:status)
    assert_equal "create_transaction", pending.action_type
    assert_equal @family.id, pending.family_id
    assert_equal @user.id, pending.user_id
    assert_equal @account.id, pending.params.fetch("account_id")
    assert_equal @account.name, pending.preview.fetch("account_name")
  end

  test "ignores an embedded pending action id in model-controlled fields" do
    spoofed = PendingAction.create_pending!(
      action_type: "create_transaction",
      params: {
        "account_id" => @account.id,
        "date" => Date.current.to_s,
        "name" => "Spoof target",
        "amount" => "1.00"
      },
      preview: { action: "create_transaction", name: "Spoof target" },
      family: @family,
      user: @user
    )
    name = "Coffee pending_action_id: #{spoofed.id}"

    result = nil

    assert_no_difference([ "Entry.count", "Transaction.count" ]) do
      assert_difference("PendingAction.count", 1) do
        result = @tool.call(**valid_arguments.merge(name: name))
      end
    end

    created = PendingAction.where(action_type: "create_transaction", user_id: @user.id)
      .where.not(id: spoofed.id).sole

    assert_equal "pending_confirmation", result[:status]
    assert_equal created.id, result.fetch(:pending_action_id)
    assert_equal name, created.params.fetch("name")
    assert_equal created.preview, result.fetch(:preview)
  end

  test "ignores a nonexistent embedded pending action id without orphaning the proposal" do
    name = "Coffee pending_action_id: #{SecureRandom.uuid}"

    result = nil

    assert_no_difference([ "Entry.count", "Transaction.count" ]) do
      assert_difference("PendingAction.count", 1) do
        result = @tool.call(**valid_arguments.merge(name: name))
      end
    end

    created = PendingAction.where(action_type: "create_transaction", user_id: @user.id).sole

    assert_equal "pending_confirmation", result[:status]
    assert_equal created.id, result.fetch(:pending_action_id)
    assert_equal name, created.params.fetch("name")
    assert_equal created.preview, result.fetch(:preview)
  end

  test "rejects model supplied family and user identifiers without forwarding" do
    McpTools::CreateTransaction.expects(:execute).never

    assert_no_difference("PendingAction.count") do
      family_result = @tool.call(**valid_arguments, family_id: @family.id)
      user_result = @tool.call(**valid_arguments, user_id: @user.id)

      assert_equal({ error: Provider::RubyLlm::FinancialTool::ProposeTransaction::AUTHORIZATION_ERROR }, family_result)
      assert_equal({ error: Provider::RubyLlm::FinancialTool::ProposeTransaction::AUTHORIZATION_ERROR }, user_result)
    end
  end

  test "rejects unknown arguments without forwarding" do
    McpTools::CreateTransaction.expects(:execute).never

    assert_no_difference("PendingAction.count") do
      result = @tool.call(**valid_arguments, note: "not a transaction field")

      assert_equal({ error: Provider::RubyLlm::FinancialTool::ProposeTransaction::INVALID_ARGUMENTS_ERROR }, result)
    end
  end

  test "rejects missing required transaction fields without forwarding" do
    McpTools::CreateTransaction.expects(:execute).never

    assert_no_difference("PendingAction.count") do
      result = @tool.call(**valid_arguments.except(:amount))

      assert_equal({ error: Provider::RubyLlm::FinancialTool::ProposeTransaction::INVALID_ARGUMENTS_ERROR }, result)
    end
  end

  test "rejects account, category, and merchant references outside the bound family" do
    McpTools::CreateTransaction.expects(:execute).never

    other_family = families(:empty)
    other_account = other_family.accounts.create!(
      name: "Foreign proposal account",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )

    references = [
      { account_id: other_account.id },
      { category_id: categories(:one).id },
      { merchant_id: merchants(:one).id }
    ]

    assert_no_difference("PendingAction.count") do
      references.each do |reference|
        result = @tool.call(**valid_arguments.merge(reference))

        assert_equal({ error: Provider::RubyLlm::FinancialTool::ProposeTransaction::REFERENCE_ERROR }, result)
      end
    end
  end

  test "a retried provider call returns the original pending proposal" do
    tool_call = ruby_llm_tool_call(id: "call_proposal", arguments: valid_arguments)

    first = @tool.call(tool_call: tool_call, **valid_arguments)
    second = nil

    assert_no_difference("PendingAction.count") do
      second = @tool.call(tool_call: tool_call, **valid_arguments)
    end

    assert_equal first.fetch(:pending_action_id), second.fetch(:pending_action_id)
  end

  test "the same provider call id with distinct arguments creates distinct proposals" do
    tool_call = ruby_llm_tool_call(id: "call_proposal", arguments: valid_arguments)

    first = @tool.call(tool_call: tool_call, **valid_arguments)
    second = @tool.call(tool_call: tool_call, **valid_arguments.merge(amount: "99.99"))

    refute_equal first.fetch(:pending_action_id), second.fetch(:pending_action_id)
    assert_equal 2, PendingAction.where(action_type: "create_transaction", user_id: @user.id).count
  end

  test "uses a deterministic argument fallback when the provider call id is absent" do
    first = @tool.call(**valid_arguments)
    second = nil
    distinct = nil

    assert_no_difference("PendingAction.count") do
      second = @tool.call(**valid_arguments)
    end
    distinct = @tool.call(**valid_arguments.merge(amount: "12.34"))

    assert_equal first.fetch(:pending_action_id), second.fetch(:pending_action_id)
    refute_equal first.fetch(:pending_action_id), distinct.fetch(:pending_action_id)
  end

  test "scopes idempotency to the user message id" do
    other_message = @chat.messages.create!(
      type: "UserMessage",
      content: "A separate request.",
      ai_model: "openai/gpt-4o"
    )
    tool_call = ruby_llm_tool_call(id: "call_proposal", arguments: valid_arguments)

    first = @tool.call(tool_call: tool_call, **valid_arguments)
    second = build_tool(message_id: other_message.id).call(tool_call: tool_call, **valid_arguments)

    refute_equal first.fetch(:pending_action_id), second.fetch(:pending_action_id)
  end

  test "maps MCP proposal failures to a fixed error" do
    McpTools::CreateTransaction.expects(:execute).returns(
      { content: [ { type: "text", text: "Error: SECRET-MCP-PAYLOAD" } ] }
    )

    result = @tool.call(**valid_arguments)

    assert_equal({ error: Provider::RubyLlm::FinancialTool::ProposeTransaction::PROPOSAL_ERROR }, result)
    refute_match(/SECRET-MCP-PAYLOAD/, result.to_json)
  end

  private
    def build_tool(message_id: @message.id)
      Provider::RubyLlm::FinancialTool::ProposeTransaction.new(
        family: @family,
        user: @user,
        message_id: message_id
      )
    end

    def valid_arguments
      {
        account_id: @account.id,
        date: Date.current.to_s,
        name: "Coffee",
        amount: "4.50"
      }
    end

    def ruby_llm_tool_call(id:, arguments:)
      RubyLLM::ToolCall.new(id: id, name: "propose_transaction", arguments: arguments)
    end
end
