module McpTools
  class ConfirmAction
    include Base

    def self.tool_name
      "confirm_action"
    end

    def self.tool_description
      "Confirm and execute a previously prepared action. Use this after the user has reviewed and approved the preview from a prepare_* tool. Requires the pending_action_id from the prepare response."
    end

    def self.tool_input_schema
      {
        type: "object",
        properties: {
          pending_action_id: {
            type: "string",
            format: "uuid",
            description: "The ID of the pending action to confirm"
          }
        },
        required: [ "pending_action_id" ]
      }
    end

    ERROR_TEXT = "Action not found, already confirmed, expired, or unsupported.".freeze
    SUPPORTED_ACTION_TYPES = %w[
      create_transaction
      update_transaction
      create_or_update_budget
      create_or_update_budget_category
    ].freeze

    def self.execute(params, user: nil, family: nil)
      return error_result unless trusted_identity?(user, family)

      id = params["pending_action_id"]
      return error_result unless valid_pending_action_id?(id)

      action = PendingAction.where(family: family).find_by(id: id)
      return error_result if action.nil?
      return error_result unless SUPPORTED_ACTION_TYPES.include?(action.action_type)
      return error_result unless references_valid?(action, family)

      confirmed = PendingAction.confirm_and_execute!(
        id: id,
        confirmed_by: user,
        family: family
      )
      return error_result if confirmed.nil?

      result = confirmed.audit_result
      status_text = result["success"] ? "SUCCESS" : "FAILED"

      response = {
        content: [
          { type: "text", text: "Action #{status_text}: #{confirmed.action_type}\nResult: #{result.to_json}" }
        ]
      }
      response[:isError] = true unless result["success"]
      response
    rescue StandardError
      error_result
    end

    def self.trusted_identity?(user, family)
      user.is_a?(User) && family.is_a?(Family) && user.family_id == family.id
    end
    private_class_method :trusted_identity?

    def self.valid_pending_action_id?(id)
      id.is_a?(String) && PendingAction::ACTION_ID_FORMAT.match?(id)
    end
    private_class_method :valid_pending_action_id?

    def self.references_valid?(action, family)
      params = action.params

      case action.action_type
      when "create_transaction"
        required_reference_valid?(params["account_id"], family.accounts) &&
          optional_reference_valid?(params["category_id"], family.categories) &&
          optional_reference_valid?(params["merchant_id"], family.merchants)
      when "update_transaction"
        optional_reference_valid?(params["category_id"], family.categories) &&
          optional_reference_valid?(params["merchant_id"], family.merchants)
      when "create_or_update_budget_category"
        params["category_id"].present? && family.categories.exists?(id: params["category_id"])
      else
        true
      end
    end
    private_class_method :references_valid?

    def self.optional_reference_valid?(id, relation)
      id.blank? || relation.exists?(id: id)
    end
    private_class_method :optional_reference_valid?

    def self.required_reference_valid?(id, relation)
      id.present? && relation.exists?(id: id)
    end
    private_class_method :required_reference_valid?

    def self.error_result
      { content: [ { type: "text", text: ERROR_TEXT } ], isError: true }
    end
    private_class_method :error_result
  end
end
