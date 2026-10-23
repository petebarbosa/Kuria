require "test_helper"

class Provider::RubyLlm::FinancialTool::GetAccountsTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @tool = Provider::RubyLlm::FinancialTool::GetAccounts.new(@family)
  end

  test "exposes the get_accounts name and an empty public argument schema" do
    assert_equal "get_accounts", Provider::RubyLlm::FinancialTool::GetAccounts.tool_name
    assert_equal "get_accounts", @tool.name

    assert_equal(
      {
        "type" => "object",
        "properties" => {},
        "required" => [],
        "additionalProperties" => false,
        "strict" => true
      },
      @tool.parameters_schema
    )
  end

  test "returns only the bound family's accounts with balance structure" do
    account = @family.accounts.create!(
      name: "Bound family checking",
      balance: 5123.45,
      currency: "USD",
      accountable: Depository.new
    )
    other_family = Family.create!(name: "Other family")
    other_family.accounts.create!(
      name: "Other family unique account",
      balance: 987_654.32,
      currency: "USD",
      accountable: Depository.new
    )

    result = @tool.call

    assert_kind_of Hash, result
    assert_kind_of String, result["as_of_date"]
    assert_kind_of Array, result["accounts"]

    bound_account = result["accounts"].find { |entry| entry["name"] == account.name }
    refute_nil bound_account
    assert_equal account.balance.to_s("F"), bound_account["balance"]
    assert_equal "USD", bound_account["currency"]
    assert_equal account.balance_money.format, bound_account["balance_formatted"]
    assert_equal "asset", bound_account["classification"]
    assert_equal "Depository", bound_account["type"]
    assert_equal false, bound_account["is_plaid_linked"]
    assert_equal "active", bound_account["status"]

    historical_balances = bound_account.fetch("historical_balances")
    assert_equal %w[end_date interval start_date values].sort, historical_balances.keys.sort
    assert_kind_of Array, historical_balances["values"]

    assert result["accounts"].none? { |entry| entry["name"] == "Other family unique account" }
    assert_equal result, JSON.parse(result.to_json)
  end

  test "rejects a family_id even when it matches the bound family without querying accounts" do
    McpTools::GetAccounts.expects(:call).never

    result = @tool.call(family_id: @family.id)

    assert_equal({ error: "Account access is restricted to the authenticated family." }, result)
  end

  test "rejects unexpected arguments without querying accounts" do
    McpTools::GetAccounts.expects(:call).never

    result = @tool.call(account_id: "anything")

    assert_equal({ error: "Invalid tool arguments." }, result)
  end

  test "maps MCP error results to a fixed failure without exposing their content" do
    McpTools::GetAccounts.expects(:call).returns(
      MCP::Tool::Response.new(
        [ { type: "text", text: "SECRET-FINANCIAL-PAYLOAD" } ],
        error: true
      )
    )

    result = @tool.call

    assert_equal({ error: "Unable to retrieve accounts." }, result)
    refute_match(/SECRET-FINANCIAL-PAYLOAD/, result.to_json)
  end

  test "maps malformed MCP results to a fixed failure without exposing their content" do
    McpTools::GetAccounts.expects(:call).returns(
      MCP::Tool::Response.new([ { type: "text", text: "SECRET-MALFORMED-PAYLOAD" } ])
    )

    result = @tool.call

    assert_equal({ error: "Unable to retrieve accounts." }, result)
    refute_match(/SECRET-MALFORMED-PAYLOAD/, result.to_json)
  end

  test "maps financial operation exceptions to a fixed failure without exposing their message" do
    McpTools::GetAccounts.expects(:call).raises(StandardError.new("SECRET-EXCEPTION-PAYLOAD"))

    result = @tool.call

    assert_equal({ error: "Unable to retrieve accounts." }, result)
    refute_match(/SECRET-EXCEPTION-PAYLOAD/, result.to_json)
  end
end
