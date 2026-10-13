class Provider
  class RubyLlm < Provider
    # Structured-output helper for merchant detection (#30).
    #
    # Mirrors the legacy OpenCode structured-output workflow so enum
    # restrictions, explicit null semantics (string and JSON null), and result
    # cardinality are preserved, and normalizes the final message into
    # provider-independent Provider::LlmConcept::AutoDetectedMerchant values.
    class AutoMerchantDetector
      RESULT_KEY = "merchants".freeze

      def initialize(transactions:, user_merchants:)
        @transactions = transactions
        @user_merchants = user_merchants
      end

      def schema
        {
          name: "auto_detect_merchants",
          strict: true,
          schema: {
            type: "object",
            properties: {
              merchants: {
                type: "array",
                description: "An array of auto-detected merchant businesses for each transaction",
                items: {
                  type: "object",
                  properties: {
                    transaction_id: {
                      type: "string",
                      description: "The internal ID of the original transaction",
                      enum: transactions.map { |transaction| transaction[:id] }
                    },
                    business_name: {
                      type: %w[string null],
                      description: "The detected business name, or null if uncertain"
                    },
                    business_url: {
                      type: %w[string null],
                      description: "The URL of the detected business, or null if uncertain"
                    }
                  },
                  required: %w[transaction_id business_name business_url],
                  additionalProperties: false
                }
              }
            },
            required: %w[merchants],
            additionalProperties: false
          }
        }
      end

      def instructions
        <<~INSTRUCTIONS.strip
          You are an assistant to a consumer personal finance app.

          Closely follow ALL the rules below while auto-detecting business names and website URLs:

          - Return 1 result per transaction
          - Correlate each transaction by ID (transaction_id)
          - Do not include the subdomain in the business_url (i.e. "amazon.com" not "www.amazon.com")
          - User merchants are considered "manual" user-generated merchants and should only be used in 100% clear cases
          - Be slightly pessimistic. We favor returning "null" over returning a false positive.
          - NEVER return a name or URL for generic transaction names (e.g. "Paycheck", "Laundromat", "Grocery store", "Local diner")

          Determining a value:

          - First attempt to determine the name + URL from your knowledge of global businesses
          - If no certain match, attempt to match one of the user-provided merchants
          - If no match, return "null"
        INSTRUCTIONS
      end

      def prompt
        <<~PROMPT.strip
          Here are the user's available merchants in JSON format:

          ```json
          #{user_merchants.to_json}
          ```

          Use BOTH your knowledge AND the user-generated merchants to auto-detect the following transactions:

          ```json
          #{transactions.to_json}
          ```

          Return "null" if you are not 80%+ confident in your answer.
        PROMPT
      end

      def build_results(final_message)
        content = StructuredOutput.content_hash!(final_message, "auto-detect-merchants")
        entries = StructuredOutput.array_of_hashes!(content, RESULT_KEY, "auto-detect-merchants")

        results = entries.map do |entry|
          transaction_id = StructuredOutput.required_id!(entry, "transaction_id", "auto-detect-merchants")
          business_name = StructuredOutput.nullable_string!(entry, "business_name", "auto-detect-merchants")
          business_url = StructuredOutput.nullable_string!(entry, "business_url", "auto-detect-merchants")

          Provider::LlmConcept::AutoDetectedMerchant.new(
            transaction_id: transaction_id,
            business_name: business_name,
            business_url: business_url
          )
        end

        StructuredOutput.reject_duplicate_ids!(entries.map { |entry| entry["transaction_id"] }, "auto-detect-merchants")

        results
      end

      private
        attr_reader :transactions, :user_merchants
    end
  end
end
