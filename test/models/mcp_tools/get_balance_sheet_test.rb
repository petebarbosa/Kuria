require "test_helper"

class McpTools::GetBalanceSheetTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @family.accounts.create!(name: "BS test account", balance: 10000, currency: "USD", accountable: Depository.new)
  end

  test "tool has correct name" do
    assert_equal "get_balance_sheet", McpTools::GetBalanceSheet.name_value
  end

  test "returns balance sheet for a family" do
    result = McpTools::GetBalanceSheet.call(
      family_id: @family.id,
      server_context: {}
    )

    assert result.is_a?(MCP::Tool::Response)
    refute result.error?
    parsed = JSON.parse(result.content.first[:text])
    assert parsed.key?("net_worth")
    assert parsed.key?("assets")
    assert parsed.key?("liabilities")
    assert parsed.key?("insights")
  end

  test "returns error for invalid family_id" do
    result = McpTools::GetBalanceSheet.call(
      family_id: "nonexistent-uuid",
      server_context: {}
    )

    assert result.error?
  end
end
