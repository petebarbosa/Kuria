module McpTools
  class CreateOrUpdateBudget
    include Base

    def self.tool_name
      "create_or_update_budget"
    end

    def self.tool_description
      "Prepare creation or update of a monthly budget total. Returns preview and pending_action_id. Does NOT save until confirm_action is called."
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
          budgeted_spending: {
            type: "string",
            description: "Total monthly budget amount as decimal string"
          }
        },
        required: %w[family_id month_year budgeted_spending]
      }
    end

    def self.execute(params, user: nil)
      family = McpTools::Base.resolve_family(params["family_id"])
      month_date = Budget.param_to_date(params["month_year"])

      existing = Budget.find_by(family: family, start_date: month_date.beginning_of_month)

      preview = {
        action: "create_or_update_budget",
        month: month_date.strftime("%B %Y"),
        operation: existing ? "update" : "create",
        budgeted_spending: params["budgeted_spending"],
        current_budgeted_spending: existing&.budgeted_spending&.to_s
      }

      pending = PendingAction.create_pending!(
        action_type: "create_or_update_budget",
        params: params,
        preview: preview,
        family: family,
        user: user
      )

      {
        content: [
          { type: "text", text: "Budget action prepared.\nPreview: #{preview.to_json}\n\nCall confirm_action with pending_action_id: #{pending.id} to execute." }
        ]
      }
    rescue => e
      { content: [ { type: "text", text: "Error: #{e.message}" } ], isError: true }
    end
  end
end
