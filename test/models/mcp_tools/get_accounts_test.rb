require "test_helper"

class McpTools::GetAccountsTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = @family.accounts.create!(name: "MCP checking", balance: 5000, currency: "USD", accountable: Depository.new)
  end

  test "tool has correct name" do
    assert_equal "get_accounts", McpTools::GetAccounts.name_value
  end

  test "returns accounts for a family" do
    result = McpTools::GetAccounts.call(
      family_id: @family.id,
      server_context: {}
    )

    assert result.is_a?(MCP::Tool::Response)
    refute result.error?
    parsed = JSON.parse(result.content.first[:text])
    assert parsed["accounts"].any? { |a| a["name"] == "MCP checking" }
  end

  test "returns error for invalid family_id" do
    result = McpTools::GetAccounts.call(
      family_id: "nonexistent-uuid",
      server_context: {}
    )

    assert result.error?
  end
end
