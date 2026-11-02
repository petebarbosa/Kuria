module McpTools
  class CreateTransaction
    include Base

    def self.tool_name
      "create_transaction"
    end

    def self.tool_description
      "Prepare a new transaction for creation. Returns a preview and pending_action_id for confirmation. Does NOT create the transaction until confirm_action is called."
    end

    def self.tool_input_schema
      {
        type: "object",
        properties: {
          family_id: {
            type: "string",
            format: "uuid",
            description: "The family ID that owns the account"
          },
          account_id: {
            type: "string",
            format: "uuid",
            description: "The account ID for this transaction"
          },
          date: {
            type: "string",
            format: "date",
            description: "Transaction date (YYYY-MM-DD)"
          },
          name: {
            type: "string",
            description: "Transaction description/name"
          },
          amount: {
            type: "string",
            description: "Amount as decimal string. Positive for expense, negative for income"
          },
          currency: {
            type: "string",
            description: "Currency code (defaults to family currency)"
          },
          category_id: {
            type: "string",
            format: "uuid",
            description: "Optional category ID"
          },
          merchant_id: {
            type: "string",
            format: "uuid",
            description: "Optional merchant ID"
          },
          kind: {
            type: "string",
            enum: %w[standard funds_movement cc_payment loan_payment one_time],
            description: "Transaction kind (defaults to standard)"
          }
        },
        required: %w[family_id account_id date name amount]
      }
    end

    def self.execute(params, user: nil, idempotency_key: nil)
      family = McpTools::Base.resolve_family(params["family_id"])
      user ||= resolve_user(params["user_id"], family)
      idempotency_key = idempotency_key.presence || params["idempotency_key"].presence

      pending = Transaction::Proposal.prepare!(
        family: family,
        params: params,
        user: user,
        idempotency_key: idempotency_key
      )

      {
        content: [
          { type: "text", text: "Transaction prepared for review.\nPreview: #{pending.preview.to_json}\n\nCall confirm_action with pending_action_id: #{pending.id} to execute." }
        ]
      }
    rescue => e
      { content: [ { type: "text", text: "Error: #{e.message}" } ], isError: true }
    end

    # The user and idempotency key are supplied by the server, never advertised
    # in the tool schema. A user id is only trusted after it resolves inside the
    # tool call's family, so it can never widen the authorization scope.
    def self.resolve_user(user_id, family)
      return nil if user_id.blank?

      family.users.find_by(id: user_id) ||
        raise(ActiveRecord::RecordNotFound, "User not found for family")
    end
    private_class_method :resolve_user
  end
end
