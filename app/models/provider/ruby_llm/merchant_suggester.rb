class Provider
  class RubyLlm < Provider
    # Structured-output helper for merchant suggestion (#30).
    #
    # Mirrors the legacy OpenCode structured-output workflow — a single object
    # with an explicit nullable merchant_id — and normalizes the final message
    # into a provider-independent Provider::LlmConcept::MerchantSuggestion. A
    # malformed or refused response fails closed rather than returning a
    # fabricated suggestion.
    class MerchantSuggester
      def initialize(raw_name:, normalized_name:, user_merchants:)
        @raw_name = raw_name
        @normalized_name = normalized_name
        @user_merchants = user_merchants
      end

      def schema
        {
          name: "suggest_merchant",
          strict: true,
          schema: {
            type: "object",
            properties: {
              merchant_id: {
                type: %w[string null],
                description: "The ID of the suggested merchant, or null if uncertain"
              },
              confidence: {
                type: "number",
                description: "Confidence score between 0.0 and 1.0"
              },
              rationale: {
                type: "string",
                description: "Brief explanation of why this merchant was suggested"
              }
            },
            required: %w[merchant_id confidence rationale],
            additionalProperties: false
          }
        }
      end

      def instructions
        <<~INSTRUCTIONS.strip
          You are an assistant to a consumer personal finance app.

          Match the transaction descriptor to one of the user's merchants.

          Rules:
          - Return merchant_id from the provided list, or null
          - Be conservative: return null if confidence is below 0.6
          - Consider abbreviations, typos, and common variations
          - Never invent a merchant not in the user's list
          - Provide brief rationale for your choice
        INSTRUCTIONS
      end

      def prompt
        <<~PROMPT.strip
          Raw transaction descriptor: #{raw_name}
          Normalized: #{normalized_name}

          Available merchants:
          #{user_merchants.to_json}

          Suggest the best matching merchant from the list above, or null if uncertain.
          Return confidence between 0.0 and 1.0.
        PROMPT
      end

      def build_result(final_message)
        content = StructuredOutput.content_hash!(final_message, "suggest-merchant")

        permitted_ids = user_merchants.map { |merchant| merchant[:id].to_s }

        Provider::LlmConcept::MerchantSuggestion.new(
          merchant_id: StructuredOutput.suggestion_merchant_id!(content, permitted_ids, "suggest-merchant"),
          confidence: StructuredOutput.suggestion_confidence!(content, "suggest-merchant"),
          rationale: StructuredOutput.required_string!(content, "rationale", "suggest-merchant")
        )
      end

      private
        attr_reader :raw_name, :normalized_name, :user_merchants
    end
  end
end
