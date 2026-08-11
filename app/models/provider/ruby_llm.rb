require "securerandom"

class Provider::RubyLlm < Provider
  include LlmConcept

  Error = Class.new(Provider::Error)

  OPENAI_BASE_URL = "https://api.openai.com/v1".freeze
  OPENCODE_GO_BASE_URL = "https://opencode.ai/zen/go/v1".freeze

  SUPPORTED_PROVIDER_REFERENCES = %w[openai opencode_go].freeze

  def supports_model?(model)
    parsed = parse_reference(model)

    parsed.present? && SUPPORTED_PROVIDER_REFERENCES.include?(parsed[:provider])
  end

  def chat_response(prompt, model:, instructions: nil, functions: [], function_results: [], streamer: nil, previous_response_id: nil)
    with_provider_response(error_transformer: error_transformer_for(model)) do
      reference = resolve_reference(model)

      context = RubyLLM.context do |config|
        config.openai_api_key = reference[:api_key]
        config.openai_api_base = reference[:base_url]
      end

      chat = context.chat(
        model: reference[:model_id],
        provider: :openai,
        assume_model_exists: reference[:assume_model_exists]
      )
      chat = chat.with_instructions(instructions) if instructions.present?

      final_message = chat.ask(prompt) do |chunk|
        next if streamer.nil?

        text = chunk.respond_to?(:content) ? chunk.content : nil
        streamer.call(ChatStreamChunk.new(type: "output_text", data: text)) if text.present?
      end

      response = build_response(final_message, model)

      streamer.call(ChatStreamChunk.new(type: "response", data: response)) if streamer.present?
      response
    end
  end

  private
    ChatMessage = Provider::LlmConcept::ChatMessage
    ChatStreamChunk = Provider::LlmConcept::ChatStreamChunk
    ChatResponse = Provider::LlmConcept::ChatResponse

    def resolve_reference(model)
      parsed = parse_reference(model)

      unless parsed
        raise Error, "Invalid model reference '#{model}'. Expected 'openai/<model>' or 'opencode_go/<model>'."
      end

      case parsed[:provider]
      when "openai"
        build_reference(parsed,
          api_key: ENV["OPENAI_API_KEY"],
          api_key_name: "OPENAI_API_KEY",
          base_url: OPENAI_BASE_URL,
          assume_model_exists: false)
      when "opencode_go"
        build_reference(parsed,
          api_key: ENV["OPENCODE_GO_API_KEY"],
          api_key_name: "OPENCODE_GO_API_KEY",
          base_url: OPENCODE_GO_BASE_URL,
          assume_model_exists: true)
      else
        raise Error, "Unknown provider '#{parsed[:provider]}' in model reference '#{model}'. Supported providers: openai, opencode_go."
      end
    end

    def build_reference(parsed, api_key:, api_key_name:, base_url:, assume_model_exists:)
      if api_key.blank?
        raise Error, "Missing #{api_key_name} for '#{parsed[:provider]}/#{parsed[:model_id]}'. Set the #{api_key_name} environment variable to use the RubyLLM provider."
      end

      parsed.merge(api_key: api_key, base_url: base_url, assume_model_exists: assume_model_exists)
    end

    def parse_reference(model)
      return nil unless model.is_a?(String)

      provider, model_id = model.split("/", 2)
      return nil if provider.blank? || model_id.blank?

      { provider: provider, model_id: model_id }
    end

    def build_response(final_message, model)
      content = final_message.respond_to?(:content) ? final_message.content.to_s : ""
      response_id = final_message.respond_to?(:id) && final_message.id.present? ? final_message.id : synthetic_response_id

      ChatResponse.new(
        id: response_id,
        model: model,
        messages: [ ChatMessage.new(id: response_id, output_text: content) ],
        function_requests: []
      )
    end

    def synthetic_response_id
      "ruby_llm_#{SecureRandom.hex(8)}"
    end

    def error_transformer_for(model)
      proc do |error|
        Error.new(
          error_message(error, model),
          details: {
            provider_reference: parse_reference(model)&.dig(:provider),
            model: model,
            error_class: error.class.name,
            retryable: retryable?(error)
          }
        )
      end
    end

    def error_message(error, model)
      case error
      when Error
        error.message
      when RubyLLM::ConfigurationError
        "RubyLLM configuration error for provider '#{provider_label(model)}'"
      when RubyLLM::ModelNotFoundError
        "RubyLLM could not resolve model '#{model}'"
      when RubyLLM::UnauthorizedError
        "RubyLLM authentication failed for provider '#{provider_label(model)}'"
      when RubyLLM::RateLimitError
        "RubyLLM rate limit exceeded for provider '#{provider_label(model)}'"
      when RubyLLM::ContextLengthExceededError
        "RubyLLM context length exceeded for model '#{model}'"
      when RubyLLM::Error
        "RubyLLM API error (#{error.class.name.split("::").last}) for provider '#{provider_label(model)}'"
      when Faraday::Error
        "RubyLLM connection error (#{error.class.name.split("::").last}) for provider '#{provider_label(model)}'"
      else
        "RubyLLM provider error (#{error.class.name})"
      end
    end

    def provider_label(model)
      parse_reference(model)&.dig(:provider) || "unknown"
    end

    def retryable?(error)
      case error
      when RubyLLM::RateLimitError, RubyLLM::ServerError, RubyLLM::ServiceUnavailableError, RubyLLM::OverloadedError
        true
      when Faraday::TimeoutError, Faraday::ConnectionFailed
        true
      else
        false
      end
    end
end
