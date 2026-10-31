class Provider::Registry
  include ActiveModel::Validations

  Error = Class.new(StandardError)

  CONCEPTS = %i[exchange_rates securities llm]

  validates :concept, inclusion: { in: CONCEPTS }

  class << self
    def for_concept(concept)
      new(concept.to_sym)
    end

    def get_provider(name)
      send(name)
    rescue NoMethodError
      raise Error.new("Provider '#{name}' not found in registry")
    end

    def plaid_provider_for_region(region)
      region.to_sym == :us ? plaid_us : plaid_eu
    end

    # Provider-independent supported-model surface for admin selection. RubyLLM
    # is the only LLM provider now, so the supported-model catalog
    # (Provider::RubyLlm::Catalog#manifest) is always exposed.
    def llm_supported_models
      Provider::RubyLlm.supported_models
    end

    # Provider-independent selectable AI model options for user-facing
    # selectors: deterministic [label, canonical_reference] pairs built from
    # the catalog's current live admission (manifest ∩ live /v1/models) for
    # accounts whose credential is configured. Accounts without a configured
    # key are skipped; catalog request/shape failures fail closed as
    # Provider::Registry::Error so callers can surface a clear error.
    def llm_selectable_models
      Provider::RubyLlm.live_selectable_models
    rescue Provider::RubyLlm::Error => error
      raise Error, "Live AI model selection is unavailable: #{error.message}"
    end

    # There is no automatic, environment, or static deployment-level default:
    # model selection is always explicit, so this stays nil. Callers must
    # supply (or have persisted) a model of their own; an unavailable or stale
    # selection requires reselection, never a silent replacement.
    def llm_default_model
      nil
    end

    # Validate an explicit model reference against the configured live model
    # membership before a request is persisted. Rejects blank, uncatalogued,
    # credential-less, unavailable, and stale references by raising Error; it
    # never substitutes another model and never falls back to the static
    # manifest when the live list omits it. A live catalog request or response
    # shape failure also fails closed as Error so callers cannot proceed on an
    # unverifiable selection.
    def validate_llm_model!(model)
      return if model.present? && valid_llm_model?(model)

      raise Error, "Unsupported AI model reference #{model.inspect}."
    rescue Provider::RubyLlm::Error => error
      raise Error, "Live AI model validation is unavailable for #{model.inspect}: #{error.message}"
    end

    def valid_llm_model?(model)
      return false if model.blank?

      ruby_llm_model_available?(model)
    end

    private
      def stripe
        secret_key = ENV["STRIPE_SECRET_KEY"]
        webhook_secret = ENV["STRIPE_WEBHOOK_SECRET"]

        return nil unless secret_key.present? && webhook_secret.present?

        Provider::Stripe.new(secret_key:, webhook_secret:)
      end

      def synth
        api_key = ENV.fetch("SYNTH_API_KEY", Setting.synth_api_key)

        return nil unless api_key.present?

        Provider::Synth.new(api_key)
      end

      def plaid_us
        config = Rails.application.config.plaid

        return nil unless config.present?

        Provider::Plaid.new(config, region: :us)
      end

      def plaid_eu
        config = Rails.application.config.plaid_eu

        return nil unless config.present?

        Provider::Plaid.new(config, region: :eu)
      end

      def github
        Provider::Github.new
      end

      def composite_exchange_rates
        freecrypto_key = Setting.freecrypto_api_key.presence || ENV["FREECRYPTO_API_KEY"]
        freecrypto = freecrypto_key.present? ? Provider::FreecryptoExchangeRates.new(api_key: freecrypto_key) : nil

        Provider::CompositeExchangeRates.new(freecrypto: freecrypto)
      end

      def ruby_llm
        Provider::RubyLlm.new
      end

      # A RubyLLM reference is selectable only when it is catalogued, its
      # account credential is configured, and it is currently admitted from
      # that account's live model list (manifest ∩ live /v1/models). A failed
      # or malformed live request propagates as Provider::RubyLlm::Error so
      # callers fail closed; the static manifest is never a fallback.
      def ruby_llm_model_available?(model)
        metadata = Provider::RubyLlm::Catalog.metadata_for(model)

        return false unless metadata.present?
        return false if Provider::RubyLlm::Catalog.api_key_for(metadata[:credential_source]).blank?

        Provider::RubyLlm::Catalog.new.available?(model)
      end
  end

  def initialize(concept)
    @concept = concept
    validate!
  end

  def providers
    available_providers.map { |p| self.class.send(p) }
  end

  def get_provider(name)
    provider_method = available_providers.find { |p| p == name.to_sym }

    raise Error.new("Provider '#{name}' not found for concept: #{concept}") unless provider_method.present?

    self.class.send(provider_method)
  end

  private
    attr_reader :concept

    def available_providers
      case concept
      when :exchange_rates
        %i[composite_exchange_rates]
      when :securities
        %i[synth]
      when :llm
        %i[ruby_llm]
      else
        %i[synth plaid_us plaid_eu github]
      end
    end
end
