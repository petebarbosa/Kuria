class Provider
  class RubyLlm < Provider
    # Structured-output helper for auto-categorization (#15).
    #
    # Builds the RubyLLM JSON schema and prompts — mirroring the legacy
    # OpenCode structured-output workflow so enum restrictions, explicit null
    # semantics, and result cardinality are preserved — and normalizes the
    # final message into provider-independent
    # Provider::LlmConcept::AutoCategorization values. It never touches
    # RubyLLM beyond reading `final_message.content`, so no RubyLLM object
    # escapes the adapter.
    class AutoCategorizer
      RESULT_KEY = "categorizations".freeze
      NIL_ENUM_VALUE = "null".freeze

      def initialize(transactions:, user_categories:)
        @transactions = transactions
        @user_categories = user_categories
      end

      def schema
        {
          name: "auto_categorize",
          strict: true,
          schema: {
            type: "object",
            properties: {
              categorizations: {
                type: "array",
                description: "An array of auto-categorizations for each transaction",
                items: {
                  type: "object",
                  properties: {
                    transaction_id: {
                      type: "string",
                      description: "The internal ID of the original transaction",
                      enum: transactions.map { |transaction| transaction[:id] }
                    },
                    category_name: {
                      type: "string",
                      description: "The matched category name of the transaction, or null if no match",
                      enum: [ *user_categories.map { |category| category[:name] }, NIL_ENUM_VALUE ]
                    }
                  },
                  required: %w[transaction_id category_name],
                  additionalProperties: false
                }
              }
            },
            required: %w[categorizations],
            additionalProperties: false
          }
        }
      end

      def instructions
        <<~INSTRUCTIONS.strip
          You are an assistant to a consumer personal finance app. You will be provided a list
          of the user's transactions and a list of the user's categories. Your job is to auto-categorize
          each transaction.

          Closely follow ALL the rules below while auto-categorizing:

          - Return 1 result per transaction
          - Correlate each transaction by ID (transaction_id)
          - Attempt to match the most specific category possible (i.e. subcategory over parent category)
          - Category and transaction classifications should match (i.e. if transaction is an "expense", the category must have classification of "expense")
          - If you don't know the category, return "null"
            - You should always favor "null" over false positives
            - Be slightly pessimistic. Only match a category if you're 60%+ confident it is the correct one.
          - Each transaction has varying metadata that can be used to determine the category
            - Note: "hint" comes from 3rd party aggregators and typically represents a category name that
              may or may not match any of the user-supplied categories
        INSTRUCTIONS
      end

      def prompt
        <<~PROMPT.strip
          Here are the user's available categories in JSON format:

          ```json
          #{user_categories.to_json}
          ```

          Use the available categories to auto-categorize the following transactions:

          ```json
          #{transactions.to_json}
          ```
        PROMPT
      end

      def build_results(final_message)
        content = StructuredOutput.content_hash!(final_message, "auto-categorize")
        entries = StructuredOutput.array_of_hashes!(content, RESULT_KEY, "auto-categorize")

        entries.map do |entry|
          Provider::LlmConcept::AutoCategorization.new(
            transaction_id: entry["transaction_id"],
            category_name: StructuredOutput.nullable(entry["category_name"])
          )
        end
      end

      private
        attr_reader :transactions, :user_categories
    end
  end
end
