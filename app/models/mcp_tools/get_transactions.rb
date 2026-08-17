class McpTools::GetTransactions < MCP::Tool
  PAGE_SIZE = 50

  tool_name "get_transactions"

  description <<~DESC
    Query user financial transactions with filters. Returns paginated results.
    Required: family_id, page, order.
    Optional: search, start_date (YYYY-MM-DD), end_date (YYYY-MM-DD), accounts, categories, merchants, tags, amount, amount_operator.
    Response includes: transactions array, total_results, page, page_size, total_pages, total_income, total_expenses.
  DESC

  input_schema(
    properties: {
      family_id: { type: "string", description: "The family ID to scope the query" },
      page: { type: "integer", description: "Page number (1-indexed)" },
      order: { type: "string", enum: %w[asc desc], description: "Order transactions by date" },
      search: { type: "string", description: "Search transactions by name" },
      amount: { type: "string", description: "Amount filter (use with amount_operator)" },
      amount_operator: { type: "string", enum: %w[equal less greater], description: "Operator for amount filter" },
      start_date: { type: "string", description: "Start date in YYYY-MM-DD format" },
      end_date: { type: "string", description: "End date in YYYY-MM-DD format" },
      accounts: { type: "array", items: { type: "string" }, description: "Filter by account names" },
      categories: { type: "array", items: { type: "string" }, description: "Filter by category names" },
      merchants: { type: "array", items: { type: "string" }, description: "Filter by merchant names" },
      tags: { type: "array", items: { type: "string" }, description: "Filter by tag names" }
    },
    required: %w[family_id page order]
  )

  def self.call(server_context:, **params)
    family = McpTools::Base.resolve_family(params[:family_id])

    search_params = params.except(:family_id, :order, :page, :server_context).stringify_keys
    search = Transaction::Search.new(family, filters: search_params)
    transactions_query = search.transactions_scope
    ordered_query = params[:order] == "asc" ? transactions_query.chronological : transactions_query.reverse_chronological

    total_count = ordered_query.count
    page = params[:page] || 1
    offset = (page - 1) * PAGE_SIZE
    total_pages = (total_count.to_f / PAGE_SIZE).ceil

    paginated_transactions = ordered_query.offset(offset).limit(PAGE_SIZE).includes(
      { entry: :account },
      :category, :merchant, :tags,
      transfer_as_outflow: { inflow_transaction: { entry: :account } },
      transfer_as_inflow: { outflow_transaction: { entry: :account } }
    )

    totals = search.totals

    normalized = paginated_transactions.map do |txn|
      entry = txn.entry
      {
        date: entry.date,
        amount: entry.amount.abs,
        currency: entry.currency,
        formatted_amount: entry.amount_money.abs.format,
        classification: entry.amount < 0 ? "income" : "expense",
        account: entry.account.name,
        category: txn.category&.name,
        merchant: txn.merchant&.name,
        tags: txn.tags.map(&:name),
        is_transfer: txn.transfer?
      }
    end

    data = {
      transactions: normalized,
      total_results: total_count,
      page: page,
      page_size: PAGE_SIZE,
      total_pages: [ total_pages, 1 ].max,
      total_income: totals.income_money.format,
      total_expenses: totals.expense_money.format
    }

    MCP::Tool::Response.new([ { type: "text", text: data.to_json } ])
  rescue ArgumentError => e
    MCP::Tool::Response.new([ { type: "text", text: e.message } ], error: true)
  rescue => e
    MCP::Tool::Response.new([ { type: "text", text: "Error querying transactions: #{e.message}" } ], error: true)
  end
end
