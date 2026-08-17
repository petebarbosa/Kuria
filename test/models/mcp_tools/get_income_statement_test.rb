require "test_helper"

class McpTools::GetIncomeStatementTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @account = @family.accounts.create!(name: "IS test account", balance: 5000, currency: "USD", accountable: Depository.new)
  end

  test "tool has correct name" do
    assert_equal "get_income_statement", McpTools::GetIncomeStatement.name_value
  end

  test "returns income statement for a date range" do
    create_transaction(account: @account, name: "Salary", date: 15.days.ago, amount: -3000)
    create_transaction(account: @account, name: "Groceries", date: 10.days.ago, amount: 150)

    result = McpTools::GetIncomeStatement.call(
      family_id: @family.id,
      start_date: 30.days.ago.to_date.to_s,
      end_date: Date.current.to_s,
      server_context: {}
    )

    assert result.is_a?(MCP::Tool::Response)
    refute result.error?
    parsed = JSON.parse(result.content.first[:text])
    assert parsed.key?("income")
    assert parsed.key?("expense")
    assert parsed.key?("insights")
    assert parsed.dig("period", "start_date").present?
  end

  test "returns error for invalid family_id" do
    result = McpTools::GetIncomeStatement.call(
      family_id: "nonexistent-uuid",
      start_date: 30.days.ago.to_date.to_s,
      end_date: Date.current.to_s,
      server_context: {}
    )

    assert result.error?
  end
end
