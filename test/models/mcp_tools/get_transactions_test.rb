require "test_helper"

class McpTools::GetTransactionsTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @account = @family.accounts.create!(name: "MCP test account", balance: 1000, currency: "USD", accountable: Depository.new)
  end

  test "tool has correct name and description" do
    assert_equal "get_transactions", McpTools::GetTransactions.name_value
    assert McpTools::GetTransactions.description_value.present?
  end

  test "returns transactions for a family" do
    create_transaction(account: @account, name: "Test purchase", date: Date.current, amount: 50)

    result = McpTools::GetTransactions.call(
      family_id: @family.id,
      page: 1,
      order: "desc",
      server_context: {}
    )

    assert result.is_a?(MCP::Tool::Response)
    refute result.error?
    parsed = JSON.parse(result.content.first[:text])
    assert parsed["transactions"].any? { |t| t["account"] == "MCP test account" }
  end

  test "returns error for invalid family_id" do
    result = McpTools::GetTransactions.call(
      family_id: "nonexistent-uuid",
      page: 1,
      order: "desc",
      server_context: {}
    )

    assert result.is_a?(MCP::Tool::Response)
    assert result.error?
  end
end
