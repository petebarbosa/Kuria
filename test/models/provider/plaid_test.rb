require "test_helper"

class Provider::PlaidTest < ActiveSupport::TestCase
  setup do
    # Do not change, this is whitelisted in the Plaid Dashboard for local dev
    @redirect_url = "http://localhost:3000/accounts"

    # A specialization of Plaid client with sandbox-only extensions
    @plaid = Provider::PlaidSandbox.new

    # Stub all sandbox.plaid.com endpoints so tests are deterministic and offline
    stub_plaid_api
  end

  test "gets link token" do
    link_token = @plaid.get_link_token(
      user_id: "test-user-id",
      webhooks_url: "https://example.com/webhooks",
      redirect_url: @redirect_url
    )

    assert_match /link-sandbox-.*/, link_token.link_token
  end

  test "exchanges public token" do
    public_token = @plaid.create_public_token
    exchange_response = @plaid.exchange_public_token(public_token)

    assert_match /access-sandbox-.*/, exchange_response.access_token
  end

  test "gets item" do
    access_token = get_access_token
    item = @plaid.get_item(access_token).item

    assert_equal "ins_109508", item.institution_id
    assert_equal "First Platypus Bank", item.institution_name
  end

  test "gets item accounts" do
    access_token = get_access_token
    accounts_response = @plaid.get_item_accounts(access_token)

    assert_equal 4, accounts_response.accounts.size
  end

  test "gets item investments" do
    access_token = get_access_token
    investments_response = @plaid.get_item_investments(access_token)

    assert_equal 3, investments_response.holdings.size
    assert_equal 4, investments_response.transactions.size
  end

  test "gets item liabilities" do
    access_token = get_access_token
    liabilities_response = @plaid.get_item_liabilities(access_token)

    assert liabilities_response.credit.count > 0
    assert liabilities_response.student.count > 0
  end

  private
    def get_access_token
      public_token = @plaid.create_public_token
      exchange_response = @plaid.exchange_public_token(public_token)
      exchange_response.access_token
    end

    def stub_plaid_api
      stub_json(:post, "https://sandbox.plaid.com/link/token/create",
        link_token: "link-sandbox-abc123",
        expiration: "2026-08-15T00:00:00Z",
        request_id: "req_link_token")

      stub_json(:post, "https://sandbox.plaid.com/sandbox/public_token/create",
        public_token: "public-sandbox-abc123",
        request_id: "req_public_token")

      stub_json(:post, "https://sandbox.plaid.com/item/public_token/exchange",
        access_token: "access-sandbox-abc123",
        item_id: "item_mock_1",
        request_id: "req_exchange")

      stub_json(:post, "https://sandbox.plaid.com/item/get",
        item: item_payload,
        request_id: "req_item")

      stub_json(:post, "https://sandbox.plaid.com/accounts/get",
        accounts: account_payloads,
        item: item_payload,
        request_id: "req_accounts")

      stub_json(:post, "https://sandbox.plaid.com/investments/holdings/get",
        accounts: account_payloads,
        holdings: holdings_payloads,
        securities: securities_payloads,
        item: item_payload,
        request_id: "req_holdings")

      stub_json(:post, "https://sandbox.plaid.com/investments/transactions/get",
        accounts: account_payloads,
        securities: securities_payloads,
        investment_transactions: investment_transaction_payloads,
        total_investment_transactions: 4,
        item: item_payload,
        request_id: "req_investment_transactions")

      stub_json(:post, "https://sandbox.plaid.com/liabilities/get",
        accounts: account_payloads,
        item: item_payload,
        liabilities: { credit: credit_liability_payloads, student: student_loan_payloads },
        request_id: "req_liabilities")
    end

    def stub_json(method, url, payload)
      stub_request(method, url)
        .to_return(status: 200, body: payload.to_json, headers: { "Content-Type" => "application/json" })
    end

    def item_payload
      {
        item_id: "item_mock_1",
        institution_id: "ins_109508",
        institution_name: "First Platypus Bank",
        available_products: %w[transactions investments liabilities],
        billed_products: %w[transactions investments liabilities]
      }
    end

    def account_payloads
      [
        { account_id: "acc_mock_1", name: "Mock Checking", mask: "1111", type: "depository", subtype: "checking", balances: { current: 1000.00, available: 800.00, iso_currency_code: "USD" } },
        { account_id: "acc_mock_2", name: "Mock Brokerage", mask: "2222", type: "investment", subtype: "brokerage", balances: { current: 15000.00, available: 15000.00, iso_currency_code: "USD" } },
        { account_id: "acc_mock_3", name: "Mock Credit Card", mask: "3333", type: "credit", subtype: "credit card", balances: { current: -500.00, iso_currency_code: "USD" } },
        { account_id: "acc_mock_4", name: "Mock Student Loan", mask: "4444", type: "loan", subtype: "student", balances: { current: 20000.00, iso_currency_code: "USD" } }
      ]
    end

    def holdings_payloads
      [
        { account_id: "acc_mock_2", security_id: "sec_mock_1", institution_price: 150.00, institution_value: 1500.00, quantity: 10.00, iso_currency_code: "USD" },
        { account_id: "acc_mock_2", security_id: "sec_mock_2", institution_price: 250.00, institution_value: 2500.00, quantity: 10.00, iso_currency_code: "USD" },
        { account_id: "acc_mock_2", security_id: "sec_mock_3", institution_price: 50.00, institution_value: 500.00, quantity: 10.00, iso_currency_code: "USD" }
      ]
    end

    def securities_payloads
      [
        { security_id: "sec_mock_1", ticker_symbol: "AAPL", name: "Apple Inc.", type: "equity", is_cash_equivalent: false },
        { security_id: "sec_mock_2", ticker_symbol: "MSFT", name: "Microsoft Corp.", type: "equity", is_cash_equivalent: false },
        { security_id: "sec_mock_3", ticker_symbol: "BTC", name: "Bitcoin", type: "cryptocurrency", is_cash_equivalent: false }
      ]
    end

    def investment_transaction_payloads
      [
        { investment_transaction_id: "inv_txn_mock_1", account_id: "acc_mock_2", security_id: "sec_mock_1", date: "2026-07-01", name: "BUY AAPL", quantity: 10.00, amount: -1500.00, price: 150.00, type: "buy", subtype: "buy", iso_currency_code: "USD" },
        { investment_transaction_id: "inv_txn_mock_2", account_id: "acc_mock_2", security_id: "sec_mock_1", date: "2026-07-02", name: "SELL AAPL", quantity: 2.00, amount: 300.00, price: 150.00, type: "sell", subtype: "sell", iso_currency_code: "USD" },
        { investment_transaction_id: "inv_txn_mock_3", account_id: "acc_mock_2", security_id: "sec_mock_2", date: "2026-07-03", name: "BUY MSFT", quantity: 5.00, amount: -1250.00, price: 250.00, type: "buy", subtype: "buy", iso_currency_code: "USD" },
        { investment_transaction_id: "inv_txn_mock_4", account_id: "acc_mock_2", security_id: "sec_mock_3", date: "2026-07-04", name: "BUY BTC", quantity: 1.00, amount: -50.00, price: 50.00, type: "buy", subtype: "buy", iso_currency_code: "USD" }
      ]
    end

    def credit_liability_payloads
      [
        { account_id: "acc_mock_3", is_overdue: false, last_statement_balance: 500.00, last_payment_amount: 100.00 }
      ]
    end

    def student_loan_payloads
      [
        { account_id: "acc_mock_4", loan_name: "Mock Student Loan", origination_date: "2020-08-01", interest_rate_percentage: 5.5, last_statement_balance: 20000.00 }
      ]
    end
end
