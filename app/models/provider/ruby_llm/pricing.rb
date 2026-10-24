class Provider
  class RubyLlm < Provider
    # Explicit, conservative cost estimation for one completed RubyLLM
    # request. Kuria only prices the OpenAI account, and only from the pricing
    # data bundled with the installed RubyLLM gem (the same registry it uses
    # for model documentation). That registry is never treated as an
    # authoritative price source for OpenCode Go: Go reuses the OpenAI wire
    # protocol but is a separate billing account, and several Go model IDs
    # also exist under unrelated providers in the registry. Pricing a Go
    # request from one of those entries would silently invent a rate.
    #
    # The official OpenCode Go pricing page also publishes peak/off-peak
    # windows, so a single request cannot be priced without an explicit,
    # reliable window/account source. Until Kuria has one, Go estimates stay
    # unknown rather than guessing a window or rounding to zero.
    #
    # Unknown prices are represented as +usd: nil, known: false+ with a
    # reason; they are never collapsed to zero. A reported zero-token request
    # priced by a known OpenAI rate is a legitimate known 0.0.
    class Pricing
      # The only pricing source used for known estimates. The reference is
      # intentionally explicit so callers can persist/display provenance.
      SOURCE = "ruby_llm_bundled_registry".freeze

      UNKNOWN_PRICING_REASON = "no_authoritative_pricing_source".freeze
      UNKNOWN_USAGE_REASON = "usage_unavailable".freeze
      INCOMPLETE_USAGE_REASON = "usage_incomplete".freeze
      UNKNOWN_MODEL_REASON = "model_not_in_registry".freeze
      MISSING_RATE_REASON = "missing_rate".freeze
      PRICING_ERROR_REASON = "pricing_error".freeze

      Result = Data.define(:usd, :known, :source, :reason)

      class << self
        # +tokens+ is the allowlisted telemetry usage Hash:
        #   { input_tokens:, output_tokens:, cache_read_tokens:,
        #     cache_write_tokens:, reasoning_tokens: }
        # Every count may be nil when the provider did not report it.
        def estimate(account:, model_id:, tokens:)
          new(account: account, model_id: model_id, tokens: tokens).estimate
        end

        # Sums per-attempt estimates. The total is known only when every entry
        # is known; the first unknown entry's source/reason is preserved so an
        # incomplete or unpriced request never collapses to a false zero.
        def aggregate(results)
          results = Array(results)

          if results.empty?
            return Result.new(usd: nil, known: false, source: SOURCE, reason: UNKNOWN_USAGE_REASON)
          end

          unknown_result = results.find { |result| !result.known || result.usd.nil? }
          if unknown_result
            return Result.new(
              usd: nil,
              known: false,
              source: unknown_result.source,
              reason: unknown_result.reason || UNKNOWN_USAGE_REASON
            )
          end

          Result.new(usd: results.sum(&:usd), known: true, source: SOURCE, reason: nil)
        end
      end

      def initialize(account:, model_id:, tokens:)
        @account = account&.to_sym
        @model_id = model_id
        @tokens = tokens || {}
      end

      def estimate
        return unknown(UNKNOWN_PRICING_REASON, source: nil) unless @account == :openai
        return unknown(UNKNOWN_USAGE_REASON) unless usage_reported?
        return unknown(INCOMPLETE_USAGE_REASON) unless complete_input_and_output?

        model = registry_model
        return unknown(UNKNOWN_MODEL_REASON) unless model

        tier = model.pricing&.text_tokens&.tier_for(prompt_tokens)
        return unknown(MISSING_RATE_REASON) unless tier

        components = component_amount(tier)
        return unknown(MISSING_RATE_REASON) if components.nil?

        amount = components + reasoning_amount(tier)
        Result.new(usd: amount, known: true, source: SOURCE, reason: nil)
      rescue StandardError
        # Pricing must never break telemetry emission. Any unexpected registry
        # failure is reported as unknown, never as zero.
        unknown(PRICING_ERROR_REASON)
      end

      private

        def unknown(reason, source: SOURCE)
          Result.new(usd: nil, known: false, source: source, reason: reason)
        end

        def usage_reported?
          usage_fields.any? { |_key, value| !value.nil? }
        end

        # Input and output are the two mandatory billable buckets. A provider
        # that omits either one leaves the total unknowable, even if another
        # bucket was reported.
        def complete_input_and_output?
          !input_tokens.nil? && !output_tokens.nil?
        end

        def component_amount(tier)
          total = 0.0

          [
            [ input_tokens, tier.input_per_million ],
            [ output_tokens, tier.output_per_million ],
            [ cache_read_tokens, tier.cache_read_input_per_million ],
            [ cache_write_tokens, tier.cache_write_input_per_million ]
          ].each do |count, rate|
            next unless count.to_i.positive?
            return nil if rate.nil?

            total += count.to_i * rate / 1_000_000.0
          end

          total
        end

        # RubyLLM treats reasoning tokens as part of output unless the registry
        # publishes a distinct reasoning rate. Mirror that rule so a missing
        # reasoning rate never silently under-prices or double-prices output.
        def reasoning_amount(tier)
          return 0.0 unless reasoning_tokens.to_i.positive?

          reasoning_rate = tier.reasoning_output_per_million
          return 0.0 if reasoning_rate.nil? || reasoning_rate == tier.output_per_million

          reasoning_tokens.to_i * reasoning_rate / 1_000_000.0
        end

        def prompt_tokens
          input_tokens.to_i + cache_read_tokens.to_i + cache_write_tokens.to_i
        end

        def registry_model
          RubyLLM.models.find(@model_id, provider: :openai)
        rescue RubyLLM::ModelNotFoundError, ArgumentError
          nil
        end

        def usage_fields
          {
            input_tokens: input_tokens,
            output_tokens: output_tokens,
            cache_read_tokens: cache_read_tokens,
            cache_write_tokens: cache_write_tokens,
            reasoning_tokens: reasoning_tokens
          }
        end

        def input_tokens
          token_count(:input_tokens)
        end

        def output_tokens
          token_count(:output_tokens)
        end

        def cache_read_tokens
          token_count(:cache_read_tokens)
        end

        def cache_write_tokens
          token_count(:cache_write_tokens)
        end

        def reasoning_tokens
          token_count(:reasoning_tokens)
        end

        def token_count(key)
          value = @tokens[key]
          value = @tokens[key.to_s] if value.nil?
          value.is_a?(Integer) ? value : nil
        end
    end
  end
end
