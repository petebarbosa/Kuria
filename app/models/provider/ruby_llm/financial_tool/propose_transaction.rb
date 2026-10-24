require "digest"

class Provider
  class RubyLlm < Provider
    module FinancialTool
      # Write-capable proposal for the RubyLLM assistant (#13).
      #
      # The authenticated family and user are bound by the server at
      # construction time. They are never advertised in the tool schema and any
      # model-supplied scope identifier is rejected before a proposal is made.
      # The financial mutation stays behind PendingAction confirmation (#14);
      # this tool only prepares an inspectable proposal.
      class ProposeTransaction < RubyLLM::Tool
        AUTHORIZATION_ERROR = "Transaction proposals cannot select a family or user.".freeze
        INVALID_ARGUMENTS_ERROR = "Invalid transaction arguments.".freeze
        REFERENCE_ERROR = "The account, category, or merchant is not available to the authenticated family.".freeze
        PROPOSAL_ERROR = "Unable to prepare the transaction proposal.".freeze

        PENDING_ACTION_ID_PATTERN = /Call confirm_action with pending_action_id:\s*([0-9a-f-]{36})\s+to execute\.\s*\z/i
        PERMITTED_ARGUMENTS = %i[
          account_id date name amount currency category_id merchant_id kind
        ].freeze
        REQUIRED_ARGUMENTS = %i[account_id date name amount].freeze
        SCOPE_ARGUMENTS = %i[family_id user_id].freeze

        def self.tool_name
          "propose_transaction"
        end

        description "Prepare a new transaction for the authenticated family. Returns a pending proposal that requires explicit user confirmation; it never creates or changes a transaction."

        parameter :account_id, description: "The account ID for this transaction"
        parameter :date, description: "Transaction date (YYYY-MM-DD)"
        parameter :name, description: "Transaction description/name"
        parameter :amount, description: "Amount as a decimal string"
        parameter :currency, description: "Currency code (defaults to family currency)", required: false
        parameter :category_id, description: "Optional category ID", required: false
        parameter :merchant_id, description: "Optional merchant ID", required: false
        parameter :kind, description: "Transaction kind (defaults to standard)", required: false

        def initialize(family:, user:, message_id: nil)
          @family = family
          @user = user
          @message_id = message_id
          @scope_valid = user.present? && user.family_id == family.id
          super()
        end

        # Accepts **arguments so scope and unknown keys can be classified before
        # any proposal is attempted. The schema still advertises only the
        # transaction fields declared above.
        def execute(tool_call: nil, **arguments)
          arguments = arguments.transform_keys(&:to_sym)

          return authorization_error unless @scope_valid
          return authorization_error if (arguments.keys & SCOPE_ARGUMENTS).any?
          return validation_error unless arguments.keys.all? { |key| PERMITTED_ARGUMENTS.include?(key) }
          return validation_error unless REQUIRED_ARGUMENTS.all? { |key| arguments[key].present? }
          return reference_error unless references_valid?(arguments)

          result = McpTools::CreateTransaction.execute(
            mcp_params(arguments),
            user: @user,
            idempotency_key: idempotency_key(tool_call, arguments)
          )

          proposal_result(result)
        rescue StandardError
          proposal_error
        end

        private
          def references_valid?(arguments)
            return false unless @family.accounts.exists?(id: arguments[:account_id])
            return false unless optional_reference_valid?(arguments[:category_id], @family.categories)
            return false unless optional_reference_valid?(arguments[:merchant_id], @family.merchants)

            true
          end

          def optional_reference_valid?(id, relation)
            id.blank? || relation.exists?(id: id)
          end

          def mcp_params(arguments)
            arguments.transform_keys(&:to_s).merge("family_id" => @family.id)
          end

          def idempotency_key(tool_call, arguments)
            provider_call_id = tool_call.respond_to?(:id) ? tool_call.id.to_s.presence : nil
            digest = Digest::SHA256.hexdigest(JSON.generate(canonical_arguments(arguments)))

            [ @message_id, provider_call_id || "no-call-id", digest ].join("\0")
          end

          def canonical_arguments(value)
            case value
            when Hash
              value.map { |key, nested| [ key.to_s, canonical_arguments(nested) ] }.sort_by(&:first).to_h
            when Array
              value.map { |item| canonical_arguments(item) }
            else
              value
            end
          end

          def proposal_result(result)
            text = result.is_a?(Hash) ? result_content_text(result) : nil
            pending_id = text&.match(PENDING_ACTION_ID_PATTERN)&.[](1)
            pending = PendingAction.find_by(id: pending_id, family: @family, user: @user)
            return proposal_error if pending.nil?

            {
              status: "pending_confirmation",
              pending_action_id: pending.id,
              preview: pending.preview
            }
          end

          def result_content_text(result)
            content = result[:content] || result["content"]
            item = Array(content).first
            return unless item.is_a?(Hash)

            item[:text] || item["text"]
          end

          def authorization_error
            { error: AUTHORIZATION_ERROR }
          end

          def validation_error
            { error: INVALID_ARGUMENTS_ERROR }
          end

          def reference_error
            { error: REFERENCE_ERROR }
          end

          def proposal_error
            { error: PROPOSAL_ERROR }
          end
      end
    end
  end
end
