class McpTools::GetAccounts < MCP::Tool
  tool_name "get_accounts"

  description "Get all accounts for a family with current and historical balances. Returns account names, balances, types, classifications, and monthly balance history."

  input_schema(
    properties: {
      family_id: { type: "string", description: "The family ID to scope the query" }
    },
    required: %w[family_id]
  )

  def self.call(server_context:, **params)
    family = McpTools::Base.resolve_family(params[:family_id])

    data = {
      as_of_date: Date.current,
      accounts: family.accounts.includes(:balances).map do |account|
        {
          name: account.name,
          balance: account.balance,
          currency: account.currency,
          balance_formatted: account.balance_money.format,
          classification: account.classification,
          type: account.accountable_type,
          start_date: account.start_date,
          is_plaid_linked: account.plaid_account_id.present?,
          status: account.status,
          historical_balances: historical_balances(account)
        }
      end
    }

    MCP::Tool::Response.new([ { type: "text", text: data.to_json } ])
  rescue ArgumentError => e
    MCP::Tool::Response.new([ { type: "text", text: e.message } ], error: true)
  rescue => e
    MCP::Tool::Response.new([ { type: "text", text: "Error querying accounts: #{e.message}" } ], error: true)
  end

  private_class_method def self.historical_balances(account)
    start_date = [ account.start_date, 5.years.ago.to_date ].max
    period = Period.custom(start_date: start_date, end_date: Date.current)
    balance_series = account.balance_series(period: period, interval: "1 month")

    {
      start_date: balance_series.start_date,
      end_date: balance_series.end_date,
      interval: balance_series.interval,
      values: balance_series.values.map { |v| v.trend.current.format }
    }
  end
end
