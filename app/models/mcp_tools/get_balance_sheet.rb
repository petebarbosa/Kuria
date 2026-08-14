class McpTools::GetBalanceSheet < MCP::Tool
  include ActiveSupport::NumberHelper

  tool_name "get_balance_sheet"

  description <<~DESC
    Get the user's balance sheet with net worth, assets, liabilities, and historical monthly data.
    Great for: What is net worth? How has wealth changed over time? What is the debt-to-asset ratio?
  DESC

  input_schema(
    properties: {
      family_id: { type: "string", description: "The family ID to scope the query" }
    },
    required: %w[family_id]
  )

  def self.call(server_context:, **params)
    family = McpTools::Base.resolve_family(params[:family_id])

    observation_start_date = [ 5.years.ago.to_date, family.oldest_entry_date ].max
    period = Period.custom(start_date: observation_start_date, end_date: Date.current)

    data = {
      as_of_date: Date.current,
      oldest_account_start_date: family.oldest_entry_date,
      currency: family.currency,
      net_worth: {
        current: family.balance_sheet.net_worth_money.format,
        monthly_history: historical_data(family, period)
      },
      assets: {
        current: family.balance_sheet.assets.total_money.format,
        monthly_history: historical_data(family, period, classification: "asset")
      },
      liabilities: {
        current: family.balance_sheet.liabilities.total_money.format,
        monthly_history: historical_data(family, period, classification: "liability")
      },
      insights: insights_data(family)
    }

    MCP::Tool::Response.new([ { type: "text", text: data.to_json } ])
  rescue ArgumentError => e
    MCP::Tool::Response.new([ { type: "text", text: e.message } ], error: true)
  rescue => e
    MCP::Tool::Response.new([ { type: "text", text: "Error querying balance sheet: #{e.message}" } ], error: true)
  end

  private_class_method def self.historical_data(family, period, classification: nil)
    scope = family.accounts.visible
    scope = scope.where(classification: classification) if classification.present?

    if period.start_date == Date.current
      []
    else
      account_ids = scope.pluck(:id)

      builder = Balance::ChartSeriesBuilder.new(
        account_ids: account_ids,
        currency: family.currency,
        period: period,
        favorable_direction: "up",
        interval: "1 month"
      )

      series = builder.balance_series
      {
        start_date: series.start_date,
        end_date: series.end_date,
        interval: series.interval,
        values: series.values.map { |v| v.trend.current.format }
      }
    end
  end

  private_class_method def self.insights_data(family)
    assets = family.balance_sheet.assets.total
    liabilities = family.balance_sheet.liabilities.total
    ratio = liabilities.zero? ? 0 : (liabilities / assets.to_f)

    {
      debt_to_asset_ratio: ActiveSupport::NumberHelper.number_to_percentage(ratio * 100, precision: 0)
    }
  end
end
