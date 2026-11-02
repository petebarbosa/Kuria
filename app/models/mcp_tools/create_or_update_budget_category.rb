module McpTools
  class CreateOrUpdateBudgetCategory
    include Base

    def self.tool_name
      "create_or_update_budget_category"
    end

    def self.tool_description
      "Prepare creation or update of a budget category allocation for a specific month. Returns preview and pending_action_id. Does NOT save until confirm_action is called."
    end

    def self.tool_input_schema
      {
        type: "object",
        properties: {
          family_id: {
            type: "string",
            format: "uuid",
            description: "The family ID"
          },
          month_year: {
            type: "string",
            description: "Month in format like 'jan-2026'"
          },
          category_id: {
            type: "string",
            format: "uuid",
            description: "The category ID to allocate"
          },
          budgeted_spending: {
            type: "string",
            description: "Budgeted amount for this category as decimal string"
          }
        },
        required: %w[family_id month_year category_id budgeted_spending]
      }
    end

    def self.execute(params, user: nil)
      family = McpTools::Base.resolve_family(params["family_id"])
      month_date = Budget.param_to_date(params["month_year"])
      category = family.categories.find(params["category_id"])

      existing_budget = Budget.find_by(family: family, start_date: month_date.beginning_of_month)
      existing_bc = existing_budget&.budget_categories&.find_by(category_id: category.id)

      preview = {
        action: "create_or_update_budget_category",
        month: month_date.strftime("%B %Y"),
        category_name: category.name,
        operation: existing_bc ? "update" : "create",
        budgeted_spending: params["budgeted_spending"],
        current_budgeted_spending: existing_bc&.budgeted_spending&.to_s
      }

      pending = PendingAction.create_pending!(
        action_type: "create_or_update_budget_category",
        params: params,
        preview: preview,
        family: family,
        user: user
      )

      {
        content: [
          { type: "text", text: "Budget category action prepared.\nPreview: #{preview.to_json}\n\nCall confirm_action with pending_action_id: #{pending.id} to execute." }
        ]
      }
    rescue ActiveRecord::RecordNotFound => e
      { content: [ { type: "text", text: "Error: #{e.message}" } ], isError: true }
    rescue => e
      { content: [ { type: "text", text: "Error: #{e.message}" } ], isError: true }
    end
  end
end
