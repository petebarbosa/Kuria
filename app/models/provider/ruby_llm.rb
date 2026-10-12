require "securerandom"

class Provider::RubyLlm < Provider
  include LlmConcept

  Error = Class.new(Provider::Error)

  OPENAI_BASE_URL = "https://api.openai.com/v1".freeze
  OPENCODE_GO_BASE_URL = "https://opencode.ai/zen/go/v1".freeze

  SUPPORTED_PROVIDER_REFERENCES = %w[openai opencode_go].freeze

  class << self
    # The immutable positive catalog (Provider::RubyLlm::Catalog#manifest) is
    # the supported-model source for admin selection. Admission authority is
    # the catalog, never RubyLLM's bundled 1.16 registry, which Kuria never
    # refreshes.
    def supported_models
      Catalog.manifest
    end

    # Provider-independent selectable options for user-facing AI model
    # selectors: deterministic [label, canonical_reference] pairs built from
    # the catalog's current live admission (manifest ∩ live /v1/models), for
    # catalog accounts whose credential is configured only. Accounts without a
    # configured key are skipped rather than failing the whole listing. Raises
    # Provider::RubyLlm::Error (typically Catalog::Error) when a configured
    # account's live model list request or response shape fails — callers must
    # fail closed.
    def live_selectable_models
      catalog = Catalog.new

      Catalog::ACCOUNTS.flat_map do |account, config|
        next [] if Catalog.api_key_for(config[:credential_source]).blank?

        catalog.available_references(account).map do |reference|
          metadata = Catalog.metadata_for(reference)
          [ "#{config[:display_name]} / #{metadata[:model_id]}", reference ]
        end
      end
    end
  end

  # Concrete canonical model references for the admin model-selection UI.
  def supported_references
    Catalog.manifest.keys
  end

  # Whether the credential required by a catalogued reference is configured.
  # Used by availability checks and the hosting UI to only offer usable models.
  def credential_configured?(reference)
    metadata = Catalog.metadata_for(reference)
    metadata.present? && Catalog.api_key_for(metadata[:credential_source]).present?
  end

  # Whether any catalog account credential is configured. Used by availability
  # checks (User#ai_available?): there is no deployment default model in RubyLLM
  # mode, so availability depends on provider keys alone.
  def credentials_configured?
    Catalog::ACCOUNTS.any? { |_account, config| Catalog.api_key_for(config[:credential_source]).present? }
  end

  # Manifest-level support check (used for provider routing). Runtime admission
  # additionally requires the live model list intersection, which happens in
  # #chat_response before a RubyLLM chat is created.
  def supports_model?(model)
    parsed = parse_reference(model)
    return false unless parsed

    Catalog.admits?(model)
  end

  def chat_response(prompt, model:, instructions: nil, functions: [], function_results: [], streamer: nil, previous_response_id: nil)
    with_provider_response(error_transformer: error_transformer_for(model)) do
      reference = resolve_reference(model)

      context = RubyLLM.context do |config|
        config.openai_api_key = reference[:api_key]
        config.openai_api_base = reference[:api_base]

        # The per-call context duplicates the global configuration, which may
        # carry OpenAI organization/project headers. Clear them ONLY for
        # OpenCode Go so a Go request never inherits the normal OpenAI billing
        # identity; normal OpenAI calls keep the deployment's own identity.
        if reference[:account] == :opencode_go
          config.openai_organization_id = nil
          config.openai_project_id = nil
        end
      end

      # The catalog is the admission authority: every admitted model is passed
      # with assume_model_exists: true (RubyLLM 1.16's bundled registry may be
      # stale for current manifest IDs and is never refreshed by Kuria).
      chat = context.chat(
        model: reference[:model_id],
        provider: reference[:provider],
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

  # Enrichment capabilities (auto-categorization, merchant detection, merchant
  # suggestion) are tracked gaps deferred to their issues; RubyLLM does not
  # implement parity here yet. These return the existing failed-Response
  # contract carrying a Provider::RubyLlm::Error (a StandardError) rather than
  # the inherited NotImplementedError crash or any placeholder success.
  def auto_categorize(transactions: [], user_categories: [])
    unsupported_capability_response(:auto_categorize)
  end

  def auto_detect_merchants(transactions: [], user_merchants: [])
    unsupported_capability_response(:auto_detect_merchants)
  end

  def suggest_merchant(raw_name:, normalized_name:, user_merchants:)
    unsupported_capability_response(:suggest_merchant)
  end

  private
    ChatMessage = Provider::LlmConcept::ChatMessage
    ChatStreamChunk = Provider::LlmConcept::ChatStreamChunk
    ChatResponse = Provider::LlmConcept::ChatResponse

    def catalog
      @catalog ||= Catalog.new
    end

    def resolve_reference(model)
      parsed = parse_reference(model)

      unless parsed
        raise Error, "Invalid model reference '#{model}'. Expected 'openai/<model>' or 'opencode_go/<model>'."
      end

      case parsed[:provider]
      when "openai"
        resolve_openai_reference(model)
      when "opencode_go"
        resolve_opencode_go_reference(model)
      else
        raise Error, "Unknown provider '#{parsed[:provider]}' in model reference '#{model}'. Supported providers: #{SUPPORTED_PROVIDER_REFERENCES.join(', ')}."
      end
    end

    def resolve_openai_reference(model)
      metadata = Catalog.metadata_for(model)

      unless metadata
        raise Error, "Unsupported OpenAI model '#{model}'. The positive OpenAI catalog only admits: #{Catalog.manifest_references(:openai).join(', ')}."
      end

      build_reference(metadata, model).tap do
        ensure_live_admission(model, :openai)
      end
    end

    def resolve_opencode_go_reference(model)
      metadata = Catalog.metadata_for(model)

      unless metadata
        raise Error, "Unsupported OpenCode Go model '#{model}'. The positive OpenCode Go catalog only admits: #{Catalog.manifest_references(:opencode_go).join(', ')}."
      end

      build_reference(metadata, model).tap do
        ensure_live_admission(model, :opencode_go)
      end
    end

    # Live catalog admission: the reference must be returned by the account's
    # live model list, intersected with the catalog. A failed or malformed
    # live request raises a catalog error (fail closed) — the manifest is
    # never a fallback for a live request, and a live list never admits an ID
    # on its own.
    def ensure_live_admission(model, account)
      return if catalog.available?(model)

      raise Error, "Model '#{model}' is catalogued for account '#{account}' but was not admitted from the live #{account} model list (IDs are intersected with the catalog; shutdown models are excluded)."
    end

    def build_reference(metadata, model)
      api_key = Catalog.api_key_for(metadata[:credential_source])

      if api_key.blank?
        raise Error, "Missing #{metadata[:credential_source]} for '#{model}'. Set the #{metadata[:credential_source]} environment variable to use the RubyLLM provider."
      end

      metadata.merge(reference: model, api_key: api_key)
    end

    def parse_reference(model)
      return nil unless model.is_a?(String)
      return nil if model.blank?

      # Reject URL/scheme payloads outright (e.g. "https://api.openai.com/v1",
      # "openai/https://example.com/gpt-4o", or "opencode_go://grok-4-fast").
      return nil if model.include?("://") || model.downcase.start_with?("http")

      # Exactly two non-empty segments: "<provider>/<model>". Extra segments,
      # empty segments, and trailing slashes are rejected.
      provider, model_id = model.split("/", 2)
      return nil if provider.blank? || model_id.blank? || model_id.include?("/")

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

    # Safe unsupported-capability failure: the existing failed-Response
    # contract with a StandardError, so callers keep their `success?` handling
    # and never see the inherited NotImplementedError (a ScriptError) or a
    # fabricated success.
    def unsupported_capability_response(capability)
      with_provider_response do
        raise Error, "The RubyLLM provider does not yet support ##{capability}; this capability is deferred to its tracked issue."
      end
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
