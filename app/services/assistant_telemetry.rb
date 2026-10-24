# Narrow, privacy-safe request telemetry for the Assistant.
#
# This is the only place that turns a provider telemetry callback event and
# Assistant tool counters into the request-level event operators consume. It
# never forwards arbitrary provider data: every nested field is rebuilt from a
# strict allowlist and every identity string is validated instead of merely
# being key-filtered. Emitting telemetry is observational; notification and
# logging failures are swallowed so they can never affect an Assistant request.
class AssistantTelemetry
  EVENT_NAME = "assistant.request.kuria".freeze

  OUTCOMES = %i[success error unknown].freeze
  PROVIDERS = %w[openai opencode_go].freeze
  USAGE_KEYS = %i[input_tokens output_tokens cache_read_tokens cache_write_tokens reasoning_tokens].freeze
  TOOL_OUTCOME_KEYS = %i[succeeded rejected failed].freeze

  COST_SOURCES = [ Provider::RubyLlm::Pricing::SOURCE ].freeze
  COST_REASONS = [
    Provider::RubyLlm::Pricing::UNKNOWN_PRICING_REASON,
    Provider::RubyLlm::Pricing::UNKNOWN_USAGE_REASON,
    Provider::RubyLlm::Pricing::INCOMPLETE_USAGE_REASON,
    Provider::RubyLlm::Pricing::UNKNOWN_MODEL_REASON,
    Provider::RubyLlm::Pricing::MISSING_RATE_REASON,
    Provider::RubyLlm::Pricing::PRICING_ERROR_REASON
  ].freeze

  UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
  NUMERIC_ID_PATTERN = /\A[1-9]\d{0,19}\z/
  ERROR_CLASS_PATTERN = /\A[A-Z][A-Za-z0-9]*(?:::[A-Z][A-Za-z0-9]*){0,8}\z/

  class << self
    # Public Assistant wiring contract:
    #
    #   AssistantTelemetry.record(
    #     message_id: message.id,
    #     chat_id: chat.id,
    #     provider_event: provider_callback_event,
    #     tool_outcomes: { succeeded: 1, rejected: 0, failed: 0 },
    #     outcome: :success,   # optional final Assistant outcome override
    #     latency_ms: 1234     # optional final Assistant latency override
    #   )
    #
    # +provider_event+ is the Hash yielded by Provider::RubyLlm's
    # telemetry_callback. Missing or malformed values become nil/zero; this
    # method never raises into the Assistant. It returns the frozen sanitized
    # event, or nil if an unexpected internal failure occurred.
    def record(message_id: nil, chat_id: nil, provider_event: nil, tool_outcomes: nil, outcome: nil, latency_ms: nil)
      event = build_event(
        message_id: message_id,
        chat_id: chat_id,
        provider_event: provider_event,
        tool_outcomes: tool_outcomes,
        outcome: outcome,
        latency_ms: latency_ms
      )

      publish(event)
      event
    rescue StandardError
      nil
    end

    private
      def build_event(message_id:, chat_id:, provider_event:, tool_outcomes:, outcome:, latency_ms:)
        source = provider_event.is_a?(Hash) ? provider_event : {}
        model = canonical_model(value(source, :model))
        provider = canonical_provider(value(source, :provider), model)
        final_outcome = sanitized_outcome(outcome, value(source, :outcome))
        final_latency = sanitized_count(latency_ms) || sanitized_count(value(source, :latency_ms))

        {
          event: EVENT_NAME,
          message_id: opaque_id(message_id),
          chat_id: opaque_id(chat_id),
          provider: provider,
          model: model,
          outcome: final_outcome,
          latency_ms: final_latency,
          retry_count: sanitized_count(value(source, :retry_count)),
          usage: sanitized_usage(value(source, :usage)),
          estimated_cost: sanitized_cost(value(source, :estimated_cost)),
          tool_outcomes: sanitized_tool_outcomes(tool_outcomes),
          error_class: final_outcome == :success ? nil : sanitized_error_class(value(source, :error_class)),
          error_retryable: final_outcome == :success ? nil : sanitized_boolean(value(source, :error_retryable))
        }.freeze
      end

      def publish(event)
        notify(event)
        log(event)
      end

      def notify(event)
        ActiveSupport::Notifications.instrument(EVENT_NAME, event)
      rescue StandardError
        nil
      end

      def log(event)
        Rails.logger.info(event.to_json)
      rescue StandardError
        nil
      end

      # Accepts either symbol or string keys from the provider callback, but
      # only the literal expected key is ever read.
      def value(source, key)
        source[key].nil? ? source[key.to_s] : source[key]
      end

      # Ids are opaque correlation handles, never free-form text. Chat ids are
      # UUIDs and message ids are positive bigints in this application.
      def opaque_id(value)
        case value
        when Integer
          value.to_s if value.positive?
        when String
          value if NUMERIC_ID_PATTERN.match?(value) || UUID_PATTERN.match?(value)
        end
      end

      # Only a catalog-admitted canonical reference is accepted. This prevents
      # an arbitrary provider/model selection string from being logged.
      def canonical_model(value)
        return nil unless value.is_a?(String)

        value if Provider::RubyLlm::Catalog.metadata_for(value).present?
      end

      def canonical_provider(value, model)
        metadata = Provider::RubyLlm::Catalog.metadata_for(model) if model
        canonical = metadata&.dig(:billing_account)

        return canonical if PROVIDERS.include?(canonical)
        return nil unless value.is_a?(String) && PROVIDERS.include?(value)

        value
      end

      def sanitized_outcome(override, provider_outcome)
        [ override, provider_outcome ].each do |candidate|
          next unless candidate.is_a?(String) || candidate.is_a?(Symbol)

          outcome = candidate.to_s.to_sym
          return outcome if OUTCOMES.include?(outcome)
        end

        :unknown
      end

      def sanitized_count(value)
        value if value.is_a?(Integer) && value >= 0
      end

      def sanitized_tool_count(value)
        sanitized_count(value) || 0
      end

      def sanitized_usage(raw)
        raw = {} unless raw.is_a?(Hash)

        USAGE_KEYS.to_h do |key|
          [ key, sanitized_count(value(raw, key)) ]
        end.freeze
      end

      def sanitized_cost(raw)
        raw = {} unless raw.is_a?(Hash)

        known = value(raw, :known) == true
        usd = sanitized_usd(value(raw, :usd))
        source = sanitized_cost_source(value(raw, :source))
        reason = sanitized_cost_reason(value(raw, :reason))

        # Known cost requires both a finite non-negative amount and an explicit
        # allowlisted source. Anything else stays unknown with nil usd.
        known = false if known && (usd.nil? || source.nil?)
        usd = nil unless known
        reason = nil if known

        {
          usd: usd,
          known: known,
          source: source,
          reason: reason
        }.freeze
      end

      def sanitized_usd(value)
        return nil unless value.is_a?(Integer) || value.is_a?(Float)

        amount = value.to_f
        amount if amount.finite? && amount >= 0
      end

      def sanitized_cost_source(value)
        value if value.is_a?(String) && COST_SOURCES.include?(value)
      end

      def sanitized_cost_reason(value)
        value if value.is_a?(String) && COST_REASONS.include?(value)
      end

      def sanitized_tool_outcomes(raw)
        raw = {} unless raw.is_a?(Hash)

        TOOL_OUTCOME_KEYS.to_h do |key|
          [ key, sanitized_tool_count(value(raw, key)) ]
        end.freeze
      end

      def sanitized_error_class(value)
        value if value.is_a?(String) && ERROR_CLASS_PATTERN.match?(value)
      end

      def sanitized_boolean(value)
        value if value == true || value == false
      end
  end
end
