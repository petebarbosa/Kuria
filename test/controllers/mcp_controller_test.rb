require "test_helper"

class McpControllerTest < ActionDispatch::IntegrationTest
  setup do
    host! "example.com"

    @user = users(:family_admin)
    @family = @user.family
    @application = Doorkeeper::Application.create!(
      name: "MCP endpoint test client",
      redirect_uri: "https://example.com/mcp/callback",
      scopes: "read read_write mcp"
    )
    @read_token_record = create_token(scopes: "mcp read")
    @read_token = @read_token_record.plaintext_token
    @write_token_record = create_token(scopes: "mcp read_write")
    @write_token = @write_token_record.plaintext_token
  end

  test "accepts an OAuth token for initialize and returns the server identity" do
    body = initialize_session(token: @read_token)

    assert_response :success
    assert_equal "2.0", body["jsonrpc"]
    assert_equal "maybe-finance", body.dig("result", "serverInfo", "name")
    assert_equal "2025-06-18", body.dig("result", "protocolVersion")
  end

  test "rejects missing, invalid, revoked, expired, and global tokens with 401" do
    post_rpc(rpc("initialize", initialize_params), token: nil)
    assert_response :unauthorized
    assert_match(/Bearer/, response.headers["WWW-Authenticate"].to_s)

    post_rpc(rpc("initialize", initialize_params), token: "invalid-token")
    assert_response :unauthorized
    assert_match(/invalid_token/, response.headers["WWW-Authenticate"].to_s)

    revoked = create_token(scopes: "mcp read")
    revoked_raw = revoked.plaintext_token
    revoked.revoke
    post_rpc(rpc("initialize", initialize_params), token: revoked_raw)
    assert_response :unauthorized

    expired_raw = create_token(
      scopes: "mcp read",
      created_at: 2.hours.ago,
      expires_in: 1.hour
    ).plaintext_token
    post_rpc(rpc("initialize", initialize_params), token: expired_raw)
    assert_response :unauthorized

    Setting.stubs(:mcp_auth_token).returns("global-mcp-token")
    post_rpc(rpc("initialize", initialize_params), token: "global-mcp-token")
    assert_response :unauthorized
  end

  test "requires mcp and read scopes, with read_write implying read" do
    mcp_only = create_token(scopes: "mcp").plaintext_token
    post_rpc(rpc("initialize", initialize_params), token: mcp_only)
    assert_response :forbidden
    assert_match(/insufficient_scope/, response.headers["WWW-Authenticate"].to_s)

    # The phase-2A verifier rejects a token missing the exact mcp scope as an
    # invalid token (401); mcp + read_write is the accepted path.
    read_write_only = create_token(scopes: "read_write").plaintext_token
    post_rpc(rpc("initialize", initialize_params), token: read_write_only)
    assert_response :unauthorized
    assert_match(/invalid_token/, response.headers["WWW-Authenticate"].to_s)

    post_rpc(rpc("initialize", initialize_params), token: @write_token)
    assert_response :success
  end

  test "lists nine tools without exchange rates or server scope fields" do
    initialize_session(token: @read_token)
    tools = list_tools(token: @read_token)

    names = tools.map { |tool| tool.fetch("name") }
    assert_equal(
      %w[
        confirm_action
        create_or_update_budget
        create_or_update_budget_category
        create_transaction
        get_accounts
        get_balance_sheet
        get_income_statement
        get_transactions
        update_transaction
      ].sort,
      names.sort
    )
    refute_includes names, "upsert_exchange_rates"

    tools.each do |tool|
      schema = tool.fetch("inputSchema")
      properties = schema.fetch("properties")
      required = schema["required"] || []

      assert_equal false, schema["additionalProperties"], tool.fetch("name")
      refute properties.key?("family_id"), tool.fetch("name")
      refute required.include?("family_id"), tool.fetch("name")
      refute properties.key?("user_id"), tool.fetch("name")
      refute properties.key?("idempotency_key"), tool.fetch("name")
    end
  end

  test "read tools are scoped to the authenticated family" do
    own_account = create_account(name: "Own scoped account")
    foreign_family = families(:empty)
    foreign_account = create_account(name: "Foreign scoped account", family: foreign_family)
    own_entry = create_entry(account: own_account, name: "Own scoped transaction")
    foreign_entry = create_entry(account: foreign_account, name: "Foreign scoped transaction")

    accounts_body = call_tool("get_accounts", {}, token: @read_token)
    assert_response :success
    assert_equal false, accounts_body.dig("result", "isError")
    assert_includes result_text(accounts_body), own_account.name
    refute_includes result_text(accounts_body), foreign_account.name

    transactions_body = call_tool(
      "get_transactions",
      { "page" => 1, "order" => "desc" },
      token: @read_token
    )
    assert_response :success
    assert_equal false, transactions_body.dig("result", "isError")
    assert_includes result_text(transactions_body), own_account.name
    refute_includes result_text(transactions_body), foreign_account.name
  end

  test "rejects model supplied scope and unknown arguments before execution" do
    entry = create_entry(account: create_account(name: "Spoof guard account"))
    foreign_family = families(:empty)
    foreign_account = create_account(name: "Spoof guard foreign account", family: foreign_family)

    assert_no_difference([ "PendingAction.count", "Entry.count" ]) do
      spoofed_scope = call_tool(
        "create_transaction",
        {
          "account_id" => foreign_account.id,
          "date" => Date.current.to_s,
          "name" => "Scope spoof",
          "amount" => "1.00",
          "family_id" => foreign_family.id
        },
        token: @write_token
      )
      assert_equal true, spoofed_scope.dig("result", "isError")

      spoofed_user = call_tool(
        "update_transaction",
        { "entry_id" => entry.id.to_s, "name" => "User spoof", "user_id" => users(:empty).id },
        token: @write_token
      )
      assert_equal true, spoofed_user.dig("result", "isError")

      unknown_argument = call_tool(
        "get_accounts",
        { "note" => "not a schema field" },
        token: @read_token
      )
      assert_equal true, unknown_argument.dig("result", "isError")
    end
  end

  test "read tokens cannot prepare or confirm write actions" do
    account = create_account(name: "Read token write account")
    pending = create_pending(family: @family, user: @user, account: account)

    assert_no_difference([ "PendingAction.count", "Entry.count", "Transaction.count" ]) do
      prepare = call_tool(
        "create_transaction",
        {
          "account_id" => account.id,
          "date" => Date.current.to_s,
          "name" => "Read token write",
          "amount" => "1.00"
        },
        token: @read_token
      )
      assert_equal true, prepare.dig("result", "isError")

      confirm = call_tool("confirm_action", { "pending_action_id" => pending.id }, token: @read_token)
      assert_equal true, confirm.dig("result", "isError")
    end

    refute pending.reload.confirmed?
  end

  test "write token prepares and confirms exactly once with the real user and family" do
    account = create_account(name: "Endpoint write account")
    create_body = nil

    assert_difference("PendingAction.count", 1) do
      create_body = call_tool(
        "create_transaction",
        {
          "account_id" => account.id,
          "date" => Date.current.to_s,
          "name" => "Endpoint write",
          "amount" => "12.34"
        },
        token: @write_token
      )
    end

    assert_equal false, create_body.dig("result", "isError")
    pending_id = result_text(create_body)[/pending_action_id:\s*([0-9a-f-]{36})/, 1]
    pending = PendingAction.find(pending_id)

    assert_equal @family.id, pending.family_id
    assert_equal @user.id, pending.user_id
    assert_equal account.id, pending.params.fetch("account_id")
    assert_equal @family.id, pending.params.fetch("family_id")

    assert_difference([ "Entry.count", "Transaction.count" ], 1) do
      confirm_body = call_tool("confirm_action", { "pending_action_id" => pending.id }, token: @write_token)

      assert_equal false, confirm_body.dig("result", "isError")
      assert_match(/Action SUCCESS: create_transaction/, result_text(confirm_body))
    end

    pending.reload
    assert pending.confirmed?
    assert_equal @user.id, pending.confirmed_by
    assert_equal @family.id, pending.family_id
    assert_equal true, pending.audit_result["success"]

    assert_no_difference([ "Entry.count", "Transaction.count" ]) do
      second = call_tool("confirm_action", { "pending_action_id" => pending.id }, token: @write_token)
      assert_equal true, second.dig("result", "isError")
    end
  end

  test "write adapters prepare updates and budgets with bound identity" do
    entry = create_entry(account: create_account(name: "Endpoint update account"))
    month = Budget.date_to_param(Date.current.beginning_of_month)

    assert_difference("PendingAction.count", 3) do
      update_body = call_tool(
        "update_transaction",
        { "entry_id" => entry.id.to_s, "name" => "Updated endpoint" },
        token: @write_token
      )
      assert_equal false, update_body.dig("result", "isError"), result_text(update_body)

      budget_body = call_tool(
        "create_or_update_budget",
        { "month_year" => month, "budgeted_spending" => "4321" },
        token: @write_token
      )
      assert_equal false, budget_body.dig("result", "isError")

      category_body = call_tool(
        "create_or_update_budget_category",
        {
          "month_year" => month,
          "category_id" => categories(:food_and_drink).id.to_s,
          "budgeted_spending" => "321"
        },
        token: @write_token
      )
      assert_equal false, category_body.dig("result", "isError")
    end

    assert_equal [ @user.id ],
      PendingAction.where(action_type: %w[update_transaction create_or_update_budget create_or_update_budget_category])
        .distinct.pluck(:user_id)
    assert_equal "Endpoint update account", entry.account.name
    assert_equal "Endpoint entry", entry.name

    pending = PendingAction.find_by!(action_type: "update_transaction")
    confirm_body = call_tool("confirm_action", { "pending_action_id" => pending.id }, token: @write_token)
    assert_equal false, confirm_body.dig("result", "isError")
    assert_equal "Updated endpoint", entry.reload.name
  end

  test "rejects foreign entry, category, and pending ids without mutation" do
    foreign_family = families(:empty)
    foreign_account = create_account(name: "Foreign endpoint account", family: foreign_family)
    foreign_entry = create_entry(account: foreign_account, name: "Foreign endpoint entry")
    foreign_pending = create_pending(
      family: foreign_family,
      user: users(:empty),
      account: foreign_account
    )
    month = Budget.date_to_param(Date.current.beginning_of_month)

    assert_no_difference([ "PendingAction.count", "Entry.count", "ExchangeRate.count" ]) do
      update_body = call_tool(
        "update_transaction",
        { "entry_id" => foreign_entry.id.to_s, "name" => "Hacked" },
        token: @write_token
      )
      assert_equal true, update_body.dig("result", "isError")

      category_body = call_tool(
        "create_or_update_budget_category",
        {
          "month_year" => month,
          "category_id" => categories(:one).id.to_s,
          "budgeted_spending" => "1"
        },
        token: @write_token
      )
      assert_equal true, category_body.dig("result", "isError")

      confirm_body = call_tool(
        "confirm_action",
        { "pending_action_id" => foreign_pending.id },
        token: @write_token
      )
      assert_equal true, confirm_body.dig("result", "isError")
      refute_includes result_text(confirm_body), foreign_pending.id
    end

    refute foreign_pending.reload.confirmed?
    assert_equal "Foreign endpoint entry", foreign_entry.reload.name
  end

  test "does not expose or confirm exchange rate actions" do
    rates_count = ExchangeRate.count
    rates = [
      {
        "from_currency" => "USD",
        "to_currency" => "EUR",
        "date" => Date.current.to_s,
        "rate" => "0.91"
      }
    ]

    tool_body = call_tool("upsert_exchange_rates", { "rates" => rates }, token: @write_token)
    assert_equal(-32602, tool_body.dig("error", "code"))
    assert_equal rates_count, ExchangeRate.count

    pending = PendingAction.create_pending!(
      action_type: "upsert_exchange_rates",
      params: { "rates" => rates },
      preview: { action: "upsert_exchange_rates", rate_count: 1 },
      family: @family,
      user: @user
    )

    confirm_body = call_tool("confirm_action", { "pending_action_id" => pending.id }, token: @write_token)
    assert_equal true, confirm_body.dig("result", "isError")
    refute pending.reload.confirmed?
    assert_equal rates_count, ExchangeRate.count
  end

  test "returns tool errors for malformed or foreign create payloads" do
    account = create_account(name: "Malformed create account")

    assert_no_difference([ "PendingAction.count", "Entry.count" ]) do
      malformed = call_tool(
        "create_transaction",
        {
          "account_id" => account.id,
          "date" => Date.current.to_s,
          "name" => "Malformed amount",
          "amount" => "not-a-number"
        },
        token: @write_token
      )
      assert_equal true, malformed.dig("result", "isError")

      missing_account = call_tool(
        "create_transaction",
        {
          "account_id" => SecureRandom.uuid,
          "date" => Date.current.to_s,
          "name" => "Missing account",
          "amount" => "1.00"
        },
        token: @write_token
      )
      assert_equal true, missing_account.dig("result", "isError")
    end
  end

  test "acknowledges notifications and handles GET and DELETE statelessly" do
    post "/mcp",
      params: { jsonrpc: "2.0", method: "notifications/initialized" }.to_json,
      headers: mcp_headers(@read_token)
    assert_response :accepted
    assert_equal "", response.body

    get "/mcp", headers: mcp_headers(@read_token)
    assert_response :method_not_allowed
    assert_equal "Method not allowed", response.parsed_body.dig("error", "message")

    delete "/mcp", headers: mcp_headers(@read_token)
    assert_response :success
    assert_equal({ "success" => true }, response.parsed_body)
  end

  test "rejects untrusted hosts and cross-origin requests" do
    host! "localhost"
    post_rpc(initialize_payload, token: @read_token)
    assert_response :success

    host! "evil.example"
    post_rpc(initialize_payload, token: @read_token)
    assert_response :forbidden

    host! "example.com"
    post "/mcp",
      params: initialize_payload.to_json,
      headers: mcp_headers(@read_token).merge("Origin" => "https://example.com")
    assert_response :success

    post "/mcp",
      params: initialize_payload.to_json,
      headers: mcp_headers(@read_token).merge("Origin" => "https://evil.example")
    assert_response :forbidden
  end

  test "rejects missing accept headers and malformed request bodies" do
    post "/mcp",
      params: initialize_payload.to_json,
      headers: mcp_headers(@read_token, accept: "")
    assert_response :not_acceptable

    post "/mcp", params: "{", headers: mcp_headers(@read_token)
    assert_response :bad_request
    assert_equal(-32700, response.parsed_body.dig("error", "code"))

    post "/mcp", params: "[{}]", headers: mcp_headers(@read_token)
    assert_response :bad_request
  end

  test "preserves finite SSE bodies instead of truncating them" do
    sse = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\n"
    MCP::Server::Transports::StreamableHTTPTransport.any_instance.stubs(:handle_request).returns(
      [ 200, { "content-type" => "text/event-stream" }, [ sse ] ]
    )

    post "/mcp", params: "{}", headers: mcp_headers(@read_token)

    assert_response :success
    assert_equal "text/event-stream", response.media_type
    assert_equal sse, response.body
  end

  private
    def create_token(scopes:, user: @user, created_at: nil, expires_in: 1.hour)
      Doorkeeper::AccessToken.create!(
        application: @application,
        resource_owner_id: user.id,
        scopes: scopes,
        expires_in: expires_in,
        created_at: created_at
      )
    end

    def create_account(name:, family: @family)
      family.accounts.create!(
        name: name,
        balance: 100,
        currency: "USD",
        accountable: Depository.new
      )
    end

    def create_entry(account:, name: "Endpoint entry", amount: 100)
      Entry.create!(
        account: account,
        date: Date.current,
        name: name,
        amount: amount,
        currency: account.currency,
        entryable: Transaction.new
      )
    end

    def create_pending(family:, user:, account: nil, name: "Endpoint pending")
      account ||= create_account(name: "#{family.id} pending account", family: family)

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

    def initialize_payload
      rpc("initialize", initialize_params)
    end

    def initialize_params
      {
        protocolVersion: "2025-06-18",
        capabilities: {},
        clientInfo: { name: "endpoint-test", version: "1.0" }
      }
    end

    def initialize_session(token: @read_token)
      post_rpc(initialize_payload, token: token)
    end

    def list_tools(token: @read_token)
      post_rpc(rpc("tools/list", {}), token: token).fetch("result").fetch("tools")
    end

    def call_tool(name, arguments, token: @read_token)
      post_rpc(rpc("tools/call", { name: name, arguments: arguments }), token: token)
    end

    def rpc(method, params = nil, id: 1)
      payload = { jsonrpc: "2.0", id: id, method: method }
      payload[:params] = params if params
      payload
    end

    def post_rpc(payload, token: @read_token, accept: "application/json, text/event-stream")
      post "/mcp",
        params: payload.is_a?(String) ? payload : payload.to_json,
        headers: mcp_headers(token, accept: accept)
      response.parsed_body
    end

    def mcp_headers(token, accept: "application/json, text/event-stream")
      headers = {
        "Content-Type" => "application/json",
        "Accept" => accept
      }
      headers["Authorization"] = "Bearer #{token}" if token
      headers
    end

    def result_text(body)
      body.dig("result", "content", 0, "text")
    end
end
