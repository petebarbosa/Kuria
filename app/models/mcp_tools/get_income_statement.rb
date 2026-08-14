class McpTools::GetIncomeStatement < MCP::Tool
  include ActiveSupport::NumberHelper

  tool_name "get_income_statement"

  description <<~DESC
    Get income and expense data by category for a specific time period.
    Great for: net income, spending habits, income/spending trends.
    Requires start_date and end_date in YYYY-MM-DD format.
  DESC

  input_schema(
    properties: {
      family_id: { type: "string", description: "The family ID to scope the query" },
      start_date: { type: "string", description: "Start date in YYYY-MM-DD format" },
      end_date: { type: "string", description: "End date in YYYY-MM-DD format" }
    },
    required: %w[family_id start_date end_date]
  )

  def self.call(server_context:, **params)
    family = McpTools::Base.resolve_family(params[:family_id])

    period = Period.custom(
      start_date: Date.parse(params[:start_date]),
      end_date: Date.parse(params[:end_date])
    )

    income_data = family.income_statement.income_totals(period: period)
    expense_data = family.income_statement.expense_totals(period: period)

    data = {
      currency: family.currency,
      period: {
        start_date: period.start_date,
        end_date: period.end_date
      },
      income: {
        total: format_money(income_data.total, family.currency),
        by_category: to_category_totals(income_data.category_totals, family.currency)
      },
      expense: {
        total: format_money(expense_data.total, family.currency),
        by_category: to_category_totals(expense_data.category_totals, family.currency)
      },
      insights: build_insights(family, income_data, expense_data)
    }

    MCP::Tool::Response.new([ { type: "text", text: data.to_json } ])
  rescue ArgumentError => e
    MCP::Tool::Response.new([ { type: "text", text: e.message } ], error: true)
  rescue => e
    MCP::Tool::Response.new([ { type: "text", text: "Error querying income statement: #{e.message}" } ], error: true)
  end

  private_class_method def self.format_money(value, currency)
    Money.new(value, currency).format
  end

  private_class_method def self.calculate_savings_rate(total_income, total_expenses)
    return 0 if total_income.zero?
    savings = total_income - total_expenses
    rate = (savings / total_income.to_f) * 100
    rate.round(2)
  end

  private_class_method def self.to_category_totals(category_totals, currency)
    hierarchical_groups = category_totals.group_by { |ct| ct.category.parent_id }.then do |grouped|
      root_category_totals = grouped[nil] || []

      root_category_totals.each_with_object({}) do |ct, hash|
        subcategory_totals = ct.category.name == "Uncategorized" ? [] : (grouped[ct.category.id] || [])
        hash[ct.category.name] = {
          category_total: ct,
          subcategory_totals: subcategory_totals
        }
      end
    end

    hierarchical_groups.sort_by { |_name, data| -data.dig(:category_total).total }.map do |name, data|
      {
        name: name,
        total: format_money(data.dig(:category_total).total, currency),
        percentage_of_total: ActiveSupport::NumberHelper.number_to_percentage(data.dig(:category_total).weight, precision: 1),
        subcategory_totals: data.dig(:subcategory_totals).map do |st|
          {
            name: st.category.name,
            total: format_money(st.total, currency),
            percentage_of_total: ActiveSupport::NumberHelper.number_to_percentage(st.weight, precision: 1)
          }
        end
      }
    end
  end

  private_class_method def self.build_insights(family, income_data, expense_data)
    net_income = income_data.total - expense_data.total
    savings_rate = calculate_savings_rate(income_data.total, expense_data.total)
    median_monthly_income = family.income_statement.median_income
    median_monthly_expenses = family.income_statement.median_expense
    avg_monthly_expenses = family.income_statement.avg_expense

    {
      net_income: format_money(net_income, family.currency),
      savings_rate: ActiveSupport::NumberHelper.number_to_percentage(savings_rate),
      median_monthly_income: format_money(median_monthly_income, family.currency),
      median_monthly_expenses: format_money(median_monthly_expenses, family.currency),
      avg_monthly_expenses: format_money(avg_monthly_expenses, family.currency)
    }
  end
end
