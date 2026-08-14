class Provider::Opencode < Provider
  include LlmConcept

  Error = Class.new(Provider::Error)

  def initialize
    @client = Provider::Opencode::Client.new(
      base_url: Setting.opencode_server_url,
      username: Setting.opencode_server_username,
      password: Setting.opencode_server_password
    )
  end

  def supports_model?(model)
    parsed_model = parse_model(model.to_s)

    parsed_model.present? && parsed_model[:providerID] == "opencode" && parsed_model[:modelID].present?
  end

  def auto_categorize(transactions: [], user_categories: [])
    with_provider_response do
      raise Error, "Too many transactions to auto-categorize. Max is 25 per request." if transactions.size > 25

      AutoCategorizer.new(
        client,
        transactions: transactions,
        user_categories: user_categories,
        model: parse_model(Setting.opencode_default_model)
      ).auto_categorize
    end
  end

  def auto_detect_merchants(transactions: [], user_merchants: [])
    with_provider_response do
      raise Error, "Too many transactions to auto-detect merchants. Max is 25 per request." if transactions.size > 25

      AutoMerchantDetector.new(
        client,
        transactions: transactions,
        user_merchants: user_merchants,
        model: parse_model(Setting.opencode_default_model)
      ).auto_detect_merchants
    end
  end

  def chat_response(prompt, model:, instructions: nil, functions: [], function_results: [], streamer: nil, previous_response_id: nil)
    session_id = nil
    with_provider_response(error_transformer: ->(error) { chat_error_transformer(error, session_id, model) }) do
      session_id = if previous_response_id.present?
        previous_response_id
      else
        session = client.create_session(title: prompt.first(80))
        session["id"]
      end

      parsed_model = parse_model(model)
      raw_response = client.send_message(session_id,
        content: prompt,
        model: parsed_model,
        system: instructions
      )

      parsed = ChatResponseParser.new(raw_response).parsed

      if streamer.present?
        parsed.messages.each do |msg|
          streamer.call(ChatStreamChunk.new(type: "output_text", data: msg.output_text))
        end

        streamer.call(ChatStreamChunk.new(type: "response", data: parsed))
      end

      parsed
    end
  end

  def suggest_merchant(raw_name:, normalized_name:, user_merchants:)
    with_provider_response do
      MerchantSuggester.new(
        client,
        raw_name: raw_name,
        normalized_name: normalized_name,
        user_merchants: user_merchants,
        model: parse_model(Setting.opencode_default_model)
      ).suggest
    end
  end

  private
    attr_reader :client

    def chat_error_transformer(error, session_id, model)
      case error
      when Provider::Opencode::Client::InvalidResponseError, Provider::Opencode::ChatResponseParser::InvalidResponseError
        Error.new("OpenCode API response error: #{error.message}", details: {
          session_id: session_id,
          model: model,
          error_type: error.class.name
        })
      else
        default_error_transformer(error)
      end
    end

    def parse_model(model_string)
      return nil unless model_string.present?

      parts = model_string.split("/", 2)
      return nil unless parts.size == 2

      { providerID: parts[0], modelID: parts[1] }
    end
end
