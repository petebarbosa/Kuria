class Provider::Opencode::AutoCategorizer
  def initialize(client, transactions: [], user_categories: [], model: {})
    @client = client
    @transactions = transactions
    @user_categories = user_categories
    @model = model
  end

  def auto_categorize
    session = client.create_session(title: "auto-categorize")
    session_id = session["id"]

    response = client.send_message(session_id,
      content: developer_message,
      model: model,
      system: instructions,
      format: {
        type: "json_schema",
        schema: json_schema
      }
    )

    structured = response.dig("info", "structured_output")
    categorizations = structured&.dig("categorizations") || []

    build_response(categorizations)
  ensure
    client.delete_session(session_id) if session_id
  end

  private
    attr_reader :client, :transactions, :user_categories, :model

    AutoCategorization = Provider::LlmConcept::AutoCategorization

    def build_response(categorizations)
      categorizations.map do |categorization|
        AutoCategorization.new(
          transaction_id: categorization["transaction_id"],
          category_name: normalize_value(categorization["category_name"])
        )
      end
    end

    def normalize_value(value)
      return nil if value == "null"
      value
    end

    def json_schema
      {
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
                  enum: transactions.map { |t| t[:id] }
                },
                category_name: {
                  type: "string",
                  description: "The matched category name of the transaction, or null if no match",
                  enum: [ *user_categories.map { |c| c[:name] }, "null" ]
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
    end

    def developer_message
      <<~MESSAGE.strip
        Here are the user's available categories in JSON format:

        ```json
        #{user_categories.to_json}
        ```

        Use the available categories to auto-categorize the following transactions:

        ```json
        #{transactions.to_json}
        ```
      MESSAGE
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
end
