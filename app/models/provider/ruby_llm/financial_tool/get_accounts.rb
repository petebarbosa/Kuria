class Provider
  class RubyLlm < Provider
    module FinancialTool
      # Read-only account access for the RubyLLM assistant (#11).
      #
      # The family is bound by the server at construction time and is never
      # advertised or overridable through the tool schema. The financial query
      # itself stays in McpTools::GetAccounts so this adapter only parses its
      # existing MCP result. Failures collapse to fixed messages: exception
      # details and another family's financial data must never reach the model.
      class GetAccounts < RubyLLM::Tool
        AUTHORIZATION_ERROR = "Account access is restricted to the authenticated family.".freeze
        INVALID_ARGUMENTS_ERROR = "Invalid tool arguments.".freeze
        RETRIEVAL_ERROR = "Unable to retrieve accounts.".freeze

        def self.tool_name
          "get_accounts"
        end

        description "Get the authenticated family's accounts with current and historical balances. Returns account names, balances, types, classifications, and monthly balance history."

        def initialize(family)
          @family = family
          super()
        end

        # Accepts **arguments so model-supplied arguments can be classified
        # before any financial query runs. With no declared parameters the
        # inferred schema is an empty object with additionalProperties false, so
        # the model never sees or chooses a family.
        def execute(**arguments)
          arguments = arguments.transform_keys(&:to_sym)

          return authorization_error if arguments.key?(:family_id)
          return validation_error if arguments.any?

          result = McpTools::GetAccounts.call(server_context: {}, family_id: @family.id)
          return retrieval_error if result.error?

          parse_result(result)
        rescue StandardError
          retrieval_error
        end

        private
          def parse_result(result)
            parsed = JSON.parse(result.content.first.fetch(:text))
            return retrieval_error unless parsed.is_a?(Hash)

            parsed
          rescue StandardError
            retrieval_error
          end

          def authorization_error
            { error: AUTHORIZATION_ERROR }
          end

          def validation_error
            { error: INVALID_ARGUMENTS_ERROR }
          end

          def retrieval_error
            { error: RETRIEVAL_ERROR }
          end
      end
    end
  end
end
