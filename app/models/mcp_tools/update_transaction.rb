module McpTools
  class UpdateTransaction
    include Base

    def self.tool_name
      "update_transaction"
    end

    def self.tool_description
      "Prepare an update to an existing transaction. Returns a preview and pending_action_id for confirmation. Does NOT update until confirm_action is called."
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
          entry_id: {
            type: "string",
            format: "uuid",
            description: "The entry ID to update"
          },
          date: {
            type: "string",
            format: "date",
            description: "New transaction date (YYYY-MM-DD)"
          },
          name: {
            type: "string",
            description: "New transaction description"
          },
          amount: {
            type: "string",
            description: "New amount as decimal string"
          },
          currency: {
            type: "string",
            description: "New currency code"
          },
          category_id: {
            type: "string",
            format: "uuid",
            description: "New category ID"
          },
          merchant_id: {
            type: "string",
            format: "uuid",
            description: "New merchant ID"
          },
          kind: {
            type: "string",
            enum: %w[standard funds_movement cc_payment loan_payment one_time],
            description: "New transaction kind"
          }
        },
        required: %w[family_id entry_id]
      }
    end

    def self.execute(params, user: nil)
      family = McpTools::Base.resolve_family(params["family_id"])
      entry = Entry.joins(:account).find_by(
        id: params["entry_id"],
        entryable_type: "Transaction",
        accounts: { family_id: family.id }
      )

      unless entry
        return { content: [ { type: "text", text: "Error: Entry not found or does not belong to the specified family." } ], isError: true }
      end

      validate_reference!(params["category_id"], family.categories, "Category")
      validate_reference!(params["merchant_id"], family.merchants, "Merchant")

      preview = {
        action: "update_transaction",
        entry_id: entry.id,
        current: {
          date: entry.date.to_s,
          name: entry.name,
          amount: entry.amount.to_s,
          currency: entry.currency
        },
        changes: params.slice("date", "name", "amount", "currency", "category_id", "merchant_id", "kind").compact
      }

      pending = PendingAction.create_pending!(
        action_type: "update_transaction",
        params: params,
        preview: preview,
        family: family,
        user: user
      )

      {
        content: [
          { type: "text", text: "Transaction update prepared.\nPreview: #{preview.to_json}\n\nCall confirm_action with pending_action_id: #{pending.id} to execute." }
        ]
      }
    rescue => e
      { content: [ { type: "text", text: "Error: #{e.message}" } ], isError: true }
    end

    def self.validate_reference!(id, relation, label)
      return if id.blank? || relation.exists?(id: id)

      raise ActiveRecord::RecordNotFound, "#{label} not found for family"
    end
    private_class_method :validate_reference!
  end
end
