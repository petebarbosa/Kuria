require "test_helper"

class PendingActionTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @account = @family.accounts.create!(name: "Test account", balance: 1000, currency: "USD", accountable: Depository.new)
  end

  test "creates pending action with valid params" do
    pending = PendingAction.create_pending!(
      action_type: "create_transaction",
      params: { "account_id" => @account.id, "date" => Date.current.to_s, "name" => "Test", "amount" => "10" },
      preview: { action: "create_transaction" },
      family: @family
    )

    assert pending.persisted?
    assert pending.expires_at > Time.current
    refute pending.confirmed?
    assert_nil pending.confirmed_at
  end

  test "expired action cannot be confirmed" do
    pending = PendingAction.create_pending!(
      action_type: "create_transaction",
      params: { "account_id" => @account.id, "date" => Date.current.to_s, "name" => "Test", "amount" => "10" },
      preview: { action: "create_transaction" },
      family: @family
    )

    pending.update!(expires_at: 1.hour.ago)
    result = PendingAction.confirm_and_execute!(id: pending.id, confirmed_by: "test")

    assert_nil result
  end

  test "already confirmed action cannot be confirmed again" do
    pending = PendingAction.create_pending!(
      action_type: "create_transaction",
      params: { "account_id" => @account.id, "date" => Date.current.to_s, "name" => "Test", "amount" => "10" },
      preview: { action: "create_transaction" },
      family: @family
    )

    first = PendingAction.confirm_and_execute!(id: pending.id, confirmed_by: "test")
    assert first.present?

    second = PendingAction.confirm_and_execute!(id: pending.id, confirmed_by: "test")
    assert_nil second
  end

  test "execute_create_transaction creates entry and transaction" do
    pending = PendingAction.create_pending!(
      action_type: "create_transaction",
      params: {
        "family_id" => @family.id,
        "account_id" => @account.id,
        "date" => Date.current.to_s,
        "name" => "MCP Test Transaction",
        "amount" => "42.50"
      },
      preview: { action: "create_transaction", amount: "42.50" },
      family: @family
    )

    confirmed = PendingAction.confirm_and_execute!(id: pending.id, confirmed_by: "test")

    assert confirmed.confirmed?
    assert_equal "test", confirmed.confirmed_by
    assert confirmed.audit_result["success"]
    assert confirmed.audit_result["entry_id"].present?
    assert confirmed.audit_result["transaction_id"].present?

    entry = Entry.find(confirmed.audit_result["entry_id"])
    assert_equal "MCP Test Transaction", entry.name
    assert_equal BigDecimal("42.50"), entry.amount
  end

  test "execute_update_transaction updates existing entry" do
    entry = Entry.create!(
      account: @account,
      date: 1.day.ago.to_date,
      name: "Original",
      amount: 100,
      currency: "USD",
      entryable: Transaction.new
    )

    pending = PendingAction.create_pending!(
      action_type: "update_transaction",
      params: {
        "family_id" => @family.id,
        "entry_id" => entry.id,
        "name" => "Updated Name",
        "amount" => "200"
      },
      preview: { action: "update_transaction" },
      family: @family
    )

    confirmed = PendingAction.confirm_and_execute!(id: pending.id, confirmed_by: "test")

    assert confirmed.audit_result["success"]
    entry.reload
    assert_equal "Updated Name", entry.name
    assert_equal BigDecimal("200"), entry.amount
  end

  test "execute_update_transaction rejects entry from different family" do
    other_family = Family.create!(currency: "USD")
    other_account = other_family.accounts.create!(name: "Other", balance: 0, currency: "USD", accountable: Depository.new)
    entry = Entry.create!(
      account: other_account,
      date: Date.current,
      name: "Other family entry",
      amount: 50,
      currency: "USD",
      entryable: Transaction.new
    )

    pending = PendingAction.create_pending!(
      action_type: "update_transaction",
      params: {
        "family_id" => @family.id,
        "entry_id" => entry.id,
        "name" => "Hacked"
      },
      preview: { action: "update_transaction" },
      family: @family
    )

    confirmed = PendingAction.confirm_and_execute!(id: pending.id, confirmed_by: "test")

    assert_equal false, confirmed.audit_result["success"]
  end

  test "execute_create_or_update_budget creates budget" do
    month_param = Budget.date_to_param(Date.current.beginning_of_month)

    pending = PendingAction.create_pending!(
      action_type: "create_or_update_budget",
      params: {
        "family_id" => @family.id,
        "month_year" => month_param,
        "budgeted_spending" => "5000"
      },
      preview: { action: "create_or_update_budget" },
      family: @family
    )

    confirmed = PendingAction.confirm_and_execute!(id: pending.id, confirmed_by: "test")

    assert confirmed.audit_result["success"]
    budget = Budget.find(confirmed.audit_result["budget_id"])
    assert_equal BigDecimal("5000"), budget.budgeted_spending
  end

  test "execute_create_or_update_budget_category creates category allocation" do
    category = @family.categories.first
    month_param = Budget.date_to_param(Date.current.beginning_of_month)

    pending = PendingAction.create_pending!(
      action_type: "create_or_update_budget_category",
      params: {
        "family_id" => @family.id,
        "month_year" => month_param,
        "category_id" => category.id,
        "budgeted_spending" => "500"
      },
      preview: { action: "create_or_update_budget_category" },
      family: @family
    )

    confirmed = PendingAction.confirm_and_execute!(id: pending.id, confirmed_by: "test")

    assert confirmed.audit_result["success"]
  end

  test "execute_upsert_exchange_rates saves rates" do
    pending = PendingAction.create_pending!(
      action_type: "upsert_exchange_rates",
      params: {
        "family_id" => @family.id,
        "rates" => [
          { "from_currency" => "USD", "to_currency" => "EUR", "date" => Date.current.to_s, "rate" => "0.91" }
        ]
      },
      preview: { action: "upsert_exchange_rates", rate_count: 1 },
      family: @family
    )

    confirmed = PendingAction.confirm_and_execute!(id: pending.id, confirmed_by: "test")

    assert confirmed.audit_result["success"]
    assert_equal 1, confirmed.audit_result["upserted"]

    rate = ExchangeRate.find_by(from_currency: "USD", to_currency: "EUR", date: Date.current)
    assert_equal BigDecimal("0.91"), rate.rate
  end

  test "unknown action type raises error" do
    pending = PendingAction.create_pending!(
      action_type: "unknown_action",
      params: { "test" => "value" },
      preview: { action: "unknown" },
      family: @family
    )

    assert_raises(RuntimeError) { pending.execute! }
  end

  test "attributes a pending transaction to the provided family user" do
    pending = create_transaction_proposal(user: @user)

    assert_equal @user.id, pending.user_id
    assert_equal @user, pending.user
  end

  test "rejects a user from another family without creating a proposal" do
    assert_no_difference("PendingAction.count") do
      assert_raises(ActiveRecord::RecordNotFound) do
        create_transaction_proposal(user: users(:empty))
      end
    end
  end

  test "returns the original proposal for a retried idempotency key" do
    first = create_transaction_proposal(user: @user, idempotency_key: "provider-call-1")
    second = nil

    assert_no_difference("PendingAction.count") do
      second = create_transaction_proposal(user: @user, idempotency_key: "provider-call-1")
    end

    assert_equal first.id, second.id
    assert_equal 1, PendingAction.where(id: first.id).count
  end

  test "mcp create_transaction renders the stored preview when a retry alters financial fields" do
    params = mcp_create_transaction_params(
      "amount" => "1000.00",
      "currency" => "USD",
      "idempotency_key" => "retry-amount-1"
    )

    first = McpTools::CreateTransaction.execute(params)
    pending = PendingAction.find_by!(action_type: "create_transaction")

    assert_match pending.id, mcp_tool_text(first)
    assert_equal "1000.0", pending.preview["amount"]
    assert_equal "1000.00", pending.params["amount"]

    retried = nil
    assert_no_difference("PendingAction.count") do
      retried = McpTools::CreateTransaction.execute(params.merge("amount" => "1.00"))
    end

    assert_match pending.id, mcp_tool_text(retried)
    rendered_preview = JSON.parse(mcp_tool_text(retried)[/Preview: (\{.*\})/, 1])

    assert_equal pending.preview.stringify_keys, rendered_preview
    assert_equal "1000.0", rendered_preview["amount"]
  end

  test "scopes idempotent proposals by family, user, action, and key" do
    other_family = families(:empty)
    other_account = other_family.accounts.create!(
      name: "Other account",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )

    no_user = create_transaction_proposal(idempotency_key: "shared-call")
    other_family_proposal = create_transaction_proposal(
      family: other_family,
      params: { "account_id" => other_account.id },
      idempotency_key: "shared-call"
    )
    with_user = create_transaction_proposal(user: @user, idempotency_key: "shared-call")
    other_action = PendingAction.create_pending!(
      action_type: "update_transaction",
      params: { "test" => "value" },
      preview: { action: "update_transaction" },
      family: @family,
      user: @user,
      idempotency_key: "shared-call"
    )

    ids = [ no_user.id, other_family_proposal.id, with_user.id, other_action.id ]
    assert_equal ids.size, ids.uniq.size
  end

  test "keeps legacy behavior when user and idempotency key are omitted" do
    first = create_transaction_proposal
    second = create_transaction_proposal

    refute_equal first.id, second.id
    assert_nil first.user_id
    assert_equal 1, PendingAction.where(id: first.id).count
    assert_equal 1, PendingAction.where(id: second.id).count
  end

  test "creating a proposal does not mutate financial data" do
    assert_no_difference([ "Entry.count", "Transaction.count" ]) do
      create_transaction_proposal(user: @user, idempotency_key: "no-mutation")
    end
  end

  test "rejects an account from another family" do
    other_account = families(:empty).accounts.create!(
      name: "Foreign account",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )

    assert_no_difference("PendingAction.count") do
      assert_raises(ActiveRecord::RecordNotFound) do
        create_transaction_proposal(params: { "account_id" => other_account.id })
      end
    end
  end

  test "rejects a category from another family" do
    assert_no_difference("PendingAction.count") do
      assert_raises(ActiveRecord::RecordNotFound) do
        create_transaction_proposal(params: { "category_id" => categories(:one).id })
      end
    end
  end

  test "rejects a merchant from another family" do
    assert_no_difference("PendingAction.count") do
      assert_raises(ActiveRecord::RecordNotFound) do
        create_transaction_proposal(params: { "merchant_id" => merchants(:one).id })
      end
    end
  end

  test "accepts category and merchant references owned by the family" do
    pending = create_transaction_proposal(
      params: {
        "category_id" => categories(:food_and_drink).id,
        "merchant_id" => merchants(:netflix).id
      }
    )

    assert pending.persisted?
  end

  test "mcp create_transaction forwards server user and idempotency key" do
    params = mcp_create_transaction_params(
      "user_id" => @user.id,
      "idempotency_key" => "mcp-call-1"
    )

    assert_no_difference([ "Entry.count", "Transaction.count" ]) do
      first = McpTools::CreateTransaction.execute(params)
      pending = PendingAction.find_by!(action_type: "create_transaction", user_id: @user.id)

      assert_match pending.id, mcp_tool_text(first)
      refute pending.params.key?("user_id")
      refute pending.params.key?("idempotency_key")

      assert_no_difference("PendingAction.count") do
        second = McpTools::CreateTransaction.execute(params)
        assert_match pending.id, mcp_tool_text(second)
      end
    end
  end

  test "mcp create_transaction rejects a user outside the family" do
    params = mcp_create_transaction_params("user_id" => users(:empty).id)

    assert_no_difference([ "PendingAction.count", "Entry.count", "Transaction.count" ]) do
      result = McpTools::CreateTransaction.execute(params)
      assert_match(/User not found for family/, mcp_tool_text(result))
    end
  end

  test "mcp create_transaction accepts server user and idempotency key keywords" do
    params = mcp_create_transaction_params

    result = McpTools::CreateTransaction.execute(params, user: @user, idempotency_key: "keyword-call")

    pending = PendingAction.find_by!(action_type: "create_transaction", user_id: @user.id)
    assert_match pending.id, mcp_tool_text(result)
    refute pending.params.key?("user_id")
    refute pending.params.key?("idempotency_key")
  end

  test "mcp create_transaction does not advertise server attribution keys" do
    properties = McpTools::CreateTransaction.tool_input_schema[:properties].keys.map(&:to_s)

    refute_includes properties, "user_id"
    refute_includes properties, "idempotency_key"
  end

  test "mcp create_transaction keeps legacy params shape without attribution" do
    params = mcp_create_transaction_params

    assert_difference("PendingAction.count", 1) do
      result = McpTools::CreateTransaction.execute(params)

      pending = PendingAction.find_by!(action_type: "create_transaction")
      assert_nil pending.user_id
      assert_equal params, pending.params
      assert_match pending.id, mcp_tool_text(result)
    end
  end

  private
    def create_transaction_proposal(**options)
      PendingAction.create_pending!(
        action_type: options.delete(:action_type) || "create_transaction",
        params: transaction_proposal_params(options.delete(:params) || {}),
        preview: { action: "create_transaction" },
        family: options.delete(:family) || @family,
        user: options.delete(:user),
        idempotency_key: options.delete(:idempotency_key)
      )
    end

    def transaction_proposal_params(overrides = {})
      {
        "account_id" => @account.id,
        "date" => Date.current.to_s,
        "name" => "Proposal",
        "amount" => "15.00"
      }.merge(overrides)
    end

    def mcp_create_transaction_params(overrides = {})
      {
        "family_id" => @family.id,
        "account_id" => @account.id,
        "date" => Date.current.to_s,
        "name" => "MCP proposal",
        "amount" => "25.00"
      }.merge(overrides)
    end

    def mcp_tool_text(result)
      result[:content].first[:text]
    end
end
