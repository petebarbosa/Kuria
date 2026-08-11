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

      def opencode
        url = Setting.opencode_server_url
        return nil unless url.present?

        Provider::Opencode.new
      end

      def ruby_llm
        return nil unless ruby_llm_provider_enabled?

        Provider::RubyLlm.new
      end

      def ruby_llm_provider_enabled?
        value = ENV["KURIA_LLM_PROVIDER"].to_s.strip

        case value
        when "", "opencode"
          false
        when "ruby_llm"
          true
        else
          raise Error, "Unknown LLM provider '#{value}' for KURIA_LLM_PROVIDER. Use 'ruby_llm' to enable the RubyLLM proof of concept, or leave it unset (or set it to 'opencode') to keep the current OpenCode behavior."
        end
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
        self.class.send(:ruby_llm_provider_enabled?) ? %i[ruby_llm] : %i[opencode]
      else
        %i[synth plaid_us plaid_eu github opencode]
      end
    end
end
