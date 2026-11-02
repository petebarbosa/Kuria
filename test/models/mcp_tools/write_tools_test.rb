require "test_helper"

class McpTools::WriteToolsTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @account = @family.accounts.create!(
      name: "Write tools account",
      balance: 1000,
      currency: "USD",
      accountable: Depository.new
    )
  end

  test "update_transaction prepares a family-bound pending update" do
    entry = create_entry(account: @account, name: "Original")
    params = update_params(entry: entry, name: "Updated")

    result = McpTools::UpdateTransaction.execute(params)

    assert_match(/Transaction update prepared/, tool_text(result))
    pending = PendingAction.where(action_type: "update_transaction").sole
    assert_equal @family.id, pending.family_id
    assert_nil pending.user_id
    assert_equal "Updated", pending.preview.fetch("changes").fetch("name")
    assert_equal "Original", entry.reload.name
  end

  test "create_or_update_budget prepares a family-bound pending budget" do
    month = Budget.date_to_param(Date.current.beginning_of_month)

    result = McpTools::CreateOrUpdateBudget.execute(
      {
        "family_id" => @family.id,
        "month_year" => month,
        "budgeted_spending" => "5000"
      }
    )

    assert_match(/Budget action prepared/, tool_text(result))
    pending = PendingAction.where(action_type: "create_or_update_budget").sole
    assert_equal @family.id, pending.family_id
    assert_nil pending.user_id
    assert_equal "5000", pending.preview.fetch("budgeted_spending")
  end

  test "create_or_update_budget_category prepares a family-bound pending allocation" do
    month = Budget.date_to_param(Date.current.beginning_of_month)

    result = McpTools::CreateOrUpdateBudgetCategory.execute(
      {
        "family_id" => @family.id,
        "month_year" => month,
        "category_id" => categories(:food_and_drink).id,
        "budgeted_spending" => "500"
      }
    )

    assert_match(/Budget category action prepared/, tool_text(result))
    pending = PendingAction.where(action_type: "create_or_update_budget_category").sole
    assert_equal @family.id, pending.family_id
    assert_nil pending.user_id
    assert_equal "Food & Drink", pending.preview.fetch("category_name")
  end

  test "write preparations assign the trusted user" do
    entry = create_entry(account: @account)
    month = Budget.date_to_param(Date.current.beginning_of_month)

    McpTools::UpdateTransaction.execute(update_params(entry: entry), user: @user)
    McpTools::CreateOrUpdateBudget.execute(budget_params(month), user: @user)
    McpTools::CreateOrUpdateBudgetCategory.execute(budget_category_params(month), user: @user)

    assert_equal [ @user.id ],
      PendingAction.where(action_type: %w[update_transaction create_or_update_budget create_or_update_budget_category])
        .distinct.pluck(:user_id)
  end

  test "write preparations do not mutate financial data" do
    entry = create_entry(account: @account)
    month = Budget.date_to_param(Date.current.beginning_of_month)

    assert_no_difference([ "Entry.count", "Transaction.count", "Budget.count", "BudgetCategory.count", "ExchangeRate.count" ]) do
      McpTools::UpdateTransaction.execute(update_params(entry: entry), user: @user)
      McpTools::CreateOrUpdateBudget.execute(budget_params(month), user: @user)
      McpTools::CreateOrUpdateBudgetCategory.execute(budget_category_params(month), user: @user)
    end
  end

  test "update_transaction rejects valuation and trade entries without creating a proposal" do
    entries = [ create_valuation_entry, create_trade_entry ]

    entries.each do |entry|
      original_amount = entry.amount

      assert_no_difference("PendingAction.count") do
        result = McpTools::UpdateTransaction.execute(
          update_params(entry: entry, name: "Mutated", amount: "999999"),
          user: @user
        )

        assert_tool_error(result)
      end

      entry.reload
      assert_equal "valuation/trade original", entry.name
      assert_equal original_amount, entry.amount
    end
  end

  test "confirm_action rejects create pendings whose category or merchant moved family" do
    category = @family.categories.create!(name: "Create stale category")
    merchant = @family.merchants.create!(name: "Create stale merchant")
    other_family = families(:empty)

    references = [
      [ { "category_id" => category.id }, -> { category.update!(family: other_family) } ],
      [ { "merchant_id" => merchant.id }, -> { merchant.update!(family: other_family) } ]
    ]

    references.each do |reference, move_reference|
      result = McpTools::CreateTransaction.execute(
        {
          "family_id" => @family.id,
          "account_id" => @account.id,
          "date" => Date.current.to_s,
          "name" => "Create stale proposal",
          "amount" => "12.34"
        }.merge(reference),
        user: @user
      )
      assert_match(/Transaction prepared for review/, tool_text(result))

      pending = PendingAction.where(action_type: "create_transaction").order(:created_at).last
      move_reference.call

      assert_no_difference([ "Entry.count", "Transaction.count" ]) do
        confirm = McpTools::ConfirmAction.execute(
          { "pending_action_id" => pending.id },
          user: @user,
          family: @family
        )

        assert_tool_error(confirm)
        assert_equal McpTools::ConfirmAction::ERROR_TEXT, tool_text(confirm)
      end

      refute pending.reload.confirmed?
    end
  end

  test "update_transaction rejects a foreign entry without creating a proposal" do
    foreign_account = families(:empty).accounts.create!(
      name: "Foreign write account",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )
    foreign_entry = create_entry(account: foreign_account, name: "Foreign entry")

    assert_no_difference("PendingAction.count") do
      result = McpTools::UpdateTransaction.execute(update_params(entry: foreign_entry), user: @user)

      assert_tool_error(result)
    end
  end

  test "update_transaction rejects foreign category and merchant references" do
    entry = create_entry(account: @account)
    references = [
      { "category_id" => categories(:one).id },
      { "merchant_id" => merchants(:one).id }
    ]

    assert_no_difference("PendingAction.count") do
      references.each do |reference|
        result = McpTools::UpdateTransaction.execute(update_params(entry: entry).merge(reference), user: @user)

        assert_tool_error(result)
      end
    end
  end

  test "write preparations reject a user from another family" do
    entry = create_entry(account: @account)
    month = Budget.date_to_param(Date.current.beginning_of_month)
    requests = [
      [ McpTools::UpdateTransaction, update_params(entry: entry) ],
      [ McpTools::CreateOrUpdateBudget, budget_params(month) ],
      [ McpTools::CreateOrUpdateBudgetCategory, budget_category_params(month) ]
    ]

    assert_no_difference("PendingAction.count") do
      requests.each do |tool, params|
        result = tool.execute(params, user: users(:empty))

        assert_tool_error(result)
      end
    end
  end

  test "write preparations ignore payload attribution and idempotency keys" do
    entry = create_entry(account: @account)
    month = Budget.date_to_param(Date.current.beginning_of_month)
    requests = [
      [ McpTools::UpdateTransaction, "update_transaction", update_params(entry: entry) ],
      [ McpTools::CreateOrUpdateBudget, "create_or_update_budget", budget_params(month) ],
      [ McpTools::CreateOrUpdateBudgetCategory, "create_or_update_budget_category", budget_category_params(month) ]
    ]

    requests.each do |tool, action_type, params|
      attributed = params.merge(
        "user_id" => users(:empty).id,
        "idempotency_key" => "payload-key"
      )

      tool.execute(attributed)
      tool.execute(attributed)

      pendings = PendingAction.where(action_type: action_type).order(:created_at).last(2)
      assert_equal 2, pendings.size, action_type
      refute_equal pendings.first.id, pendings.last.id, action_type
      assert_equal [ nil ], pendings.map(&:user_id).uniq, action_type
    end
  end

  test "confirm_action fails closed without trusted identity" do
    pending = create_transaction_pending(family: @family, user: @user)

    assert_no_difference([ "Entry.count", "Transaction.count" ]) do
      result = McpTools::ConfirmAction.execute({ "pending_action_id" => pending.id })

      assert_tool_error(result)
    end
    refute pending.reload.confirmed?
  end

  test "confirm_action does not confirm a pending action from another family" do
    other_family = families(:empty)
    foreign_pending = create_transaction_pending(family: other_family, user: users(:empty))

    assert_no_difference([ "Entry.count", "Transaction.count" ]) do
      result = McpTools::ConfirmAction.execute(
        { "pending_action_id" => foreign_pending.id },
        user: @user,
        family: @family
      )

      assert_tool_error(result)
      refute_includes tool_text(result), foreign_pending.id
    end
    refute foreign_pending.reload.confirmed?
  end

  test "confirm_action blocks legacy exchange rate pendings" do
    pending = PendingAction.create_pending!(
      action_type: "upsert_exchange_rates",
      params: {
        "rates" => [
          {
            "from_currency" => "USD",
            "to_currency" => "EUR",
            "date" => Date.current.to_s,
            "rate" => "0.91"
          }
        ]
      },
      preview: { action: "upsert_exchange_rates", rate_count: 1 },
      family: @family,
      user: @user
    )

    assert_no_difference("ExchangeRate.count") do
      result = McpTools::ConfirmAction.execute(
        { "pending_action_id" => pending.id },
        user: @user,
        family: @family
      )

      assert_tool_error(result)
    end
    refute pending.reload.confirmed?
  end

  test "confirm_action executes a prepared budget" do
    month = Budget.date_to_param(Date.current.beginning_of_month)
    McpTools::CreateOrUpdateBudget.execute(
      {
        "family_id" => @family.id,
        "month_year" => month,
        "budgeted_spending" => "4321"
      },
      user: @user
    )
    pending = PendingAction.where(action_type: "create_or_update_budget").sole

    result = McpTools::ConfirmAction.execute(
      { "pending_action_id" => pending.id },
      user: @user,
      family: @family
    )

    assert_match(/Action SUCCESS: create_or_update_budget/, tool_text(result))
    refute result[:isError]

    budget = Budget.find(pending.reload.audit_result.fetch("budget_id"))
    assert_equal BigDecimal("4321"), budget.budgeted_spending
  end

  test "confirm_action executes a prepared budget category" do
    month = Budget.date_to_param(Date.current.beginning_of_month)
    category = categories(:food_and_drink)
    McpTools::CreateOrUpdateBudgetCategory.execute(
      {
        "family_id" => @family.id,
        "month_year" => month,
        "category_id" => category.id,
        "budgeted_spending" => "321"
      },
      user: @user
    )
    pending = PendingAction.where(action_type: "create_or_update_budget_category").sole

    result = McpTools::ConfirmAction.execute(
      { "pending_action_id" => pending.id },
      user: @user,
      family: @family
    )

    assert_match(/Action SUCCESS: create_or_update_budget_category/, tool_text(result))
    refute result[:isError]

    budget_category = BudgetCategory.find(pending.reload.audit_result.fetch("budget_category_id"))
    assert_equal category.id, budget_category.category_id
    assert_equal BigDecimal("321"), budget_category.budgeted_spending
  end

  test "confirm_action executes once and records the real user and family" do
    pending = create_transaction_pending(family: @family, user: @user)

    result = nil
    assert_difference([ "Entry.count", "Transaction.count" ], 1) do
      result = McpTools::ConfirmAction.execute(
        { "pending_action_id" => pending.id },
        user: @user,
        family: @family
      )
    end

    assert_match(/Action SUCCESS: create_transaction/, tool_text(result))
    refute result[:isError]

    pending.reload
    assert pending.confirmed?
    assert_equal @user.id, pending.confirmed_by
    assert_equal @family.id, pending.family_id
    assert_equal true, pending.audit_result["success"]
    assert_equal @user.id, pending.audit_result.dig("confirmation", "confirmed_by")
    assert_equal 1, pending.audit_result["confirmation_attempts"].count { |attempt| attempt["status"] == "confirmed" }

    assert_no_difference([ "Entry.count", "Transaction.count" ]) do
      second = McpTools::ConfirmAction.execute(
        { "pending_action_id" => pending.id },
        user: @user,
        family: @family
      )

      assert_tool_error(second)
    end
  end

  test "confirm_action allows another user from the same family" do
    pending = create_transaction_pending(family: @family, user: @user)
    other_user = users(:family_member)

    assert_difference([ "Entry.count", "Transaction.count" ], 1) do
      result = McpTools::ConfirmAction.execute(
        { "pending_action_id" => pending.id },
        user: other_user,
        family: @family
      )

      assert_match(/Action SUCCESS/, tool_text(result))
    end

    assert_equal other_user.id, pending.reload.confirmed_by
  end

  test "confirm_action returns a generic error for missing or malformed ids" do
    [ "not-a-uuid", SecureRandom.uuid ].each do |id|
      result = McpTools::ConfirmAction.execute(
        { "pending_action_id" => id },
        user: @user,
        family: @family
      )

      assert_tool_error(result)
      assert_equal McpTools::ConfirmAction::ERROR_TEXT, tool_text(result)
    end
  end

  test "confirm_action rejects expired pendings" do
    pending = create_transaction_pending(family: @family, user: @user)
    pending.update!(expires_at: 1.hour.ago)

    assert_no_difference([ "Entry.count", "Transaction.count" ]) do
      result = McpTools::ConfirmAction.execute(
        { "pending_action_id" => pending.id },
        user: @user,
        family: @family
      )

      assert_tool_error(result)
      assert_equal McpTools::ConfirmAction::ERROR_TEXT, tool_text(result)
    end

    refute pending.reload.confirmed?
  end

  test "confirm_action rejects an identity from another family" do
    pending = create_transaction_pending(family: @family, user: @user)

    assert_no_difference([ "Entry.count", "Transaction.count" ]) do
      result = McpTools::ConfirmAction.execute(
        { "pending_action_id" => pending.id },
        user: users(:empty),
        family: @family
      )

      assert_tool_error(result)
    end

    refute pending.reload.confirmed?
  end

  test "confirm_action surfaces failed execution with isError" do
    entry = create_entry(account: @account)
    McpTools::UpdateTransaction.execute(
      update_params(entry: entry, kind: "not_a_valid_kind"),
      user: @user
    )
    pending = PendingAction.where(action_type: "update_transaction").sole

    result = McpTools::ConfirmAction.execute(
      { "pending_action_id" => pending.id },
      user: @user,
      family: @family
    )

    assert_tool_error(result)
    assert_match(/Action FAILED: update_transaction/, tool_text(result))

    pending.reload
    assert pending.confirmed?
    assert_equal false, pending.audit_result["success"]
  end

  test "confirm_action revalidates update and budget category references" do
    entry = create_entry(account: @account)
    stale_category = @family.categories.create!(name: "Stale category")
    McpTools::UpdateTransaction.execute(
      update_params(entry: entry).merge("category_id" => stale_category.id),
      user: @user
    )
    update_pending = PendingAction.where(action_type: "update_transaction").sole
    stale_category.destroy!

    result = McpTools::ConfirmAction.execute(
      { "pending_action_id" => update_pending.id },
      user: @user,
      family: @family
    )

    assert_tool_error(result)
    assert_equal McpTools::ConfirmAction::ERROR_TEXT, tool_text(result)
    refute update_pending.reload.confirmed?
    assert_equal "Original", entry.reload.name

    month = Budget.date_to_param(Date.current.beginning_of_month)
    budget_pending = PendingAction.create_pending!(
      action_type: "create_or_update_budget_category",
      params: {
        "month_year" => month,
        "category_id" => categories(:one).id,
        "budgeted_spending" => "100"
      },
      preview: { action: "create_or_update_budget_category" },
      family: @family,
      user: @user
    )

    result = McpTools::ConfirmAction.execute(
      { "pending_action_id" => budget_pending.id },
      user: @user,
      family: @family
    )

    assert_tool_error(result)
    assert_equal McpTools::ConfirmAction::ERROR_TEXT, tool_text(result)
    refute budget_pending.reload.confirmed?
  end

  test "create_or_update_budget_category rejects a foreign category" do
    month = Budget.date_to_param(Date.current.beginning_of_month)

    assert_no_difference("PendingAction.count") do
      result = McpTools::CreateOrUpdateBudgetCategory.execute(
        budget_category_params(month, category: categories(:one)),
        user: @user
      )

      assert_tool_error(result)
    end
  end

  private
    def create_transaction_pending(family:, user:, name: "Confirm me")
      account = family.accounts.create!(
        name: "#{family.id} confirm account",
        balance: 100,
        currency: "USD",
        accountable: Depository.new
      )

      PendingAction.create_pending!(
        action_type: "create_transaction",
        params: {
          "account_id" => account.id,
          "date" => Date.current.to_s,
          "name" => name,
          "amount" => "12.34"
        },
        preview: { action: "create_transaction", name: name },
        family: family,
        user: user
      )
    end

    def budget_params(month)
      {
        "family_id" => @family.id,
        "month_year" => month,
        "budgeted_spending" => "5000"
      }
    end

    def budget_category_params(month, category: categories(:food_and_drink))
      {
        "family_id" => @family.id,
        "month_year" => month,
        "category_id" => category.id,
        "budgeted_spending" => "500"
      }
    end

    def assert_tool_error(result)
      assert_equal true, result[:isError], "expected isError true, got: #{tool_text(result)}"
    end

    def create_entry(account:, name: "Original", amount: 100)
      Entry.create!(
        account: account,
        date: Date.current,
        name: name,
        amount: amount,
        currency: account.currency,
        entryable: Transaction.new
      )
    end

    def create_valuation_entry
      Entry.create!(
        account: @account,
        date: Date.current,
        name: "valuation/trade original",
        amount: 100,
        currency: "USD",
        entryable: Valuation.new(kind: "reconciliation")
      )
    end

    def create_trade_entry
      Entry.create!(
        account: @account,
        date: Date.current,
        name: "valuation/trade original",
        amount: 100,
        currency: "USD",
        entryable: Trade.new(security: securities(:aapl), qty: 1, price: 100, currency: "USD")
      )
    end

    def update_params(entry:, **attrs)
      {
        "family_id" => @family.id,
        "entry_id" => entry.id,
        "name" => "Updated"
      }.merge(attrs.transform_keys(&:to_s))
    end

    def tool_text(result)
      result.fetch(:content).first.fetch(:text)
    end
end
