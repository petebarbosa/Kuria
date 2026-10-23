class Provider
  class RubyLlm < Provider
    # Dedicated, immutable, positive model catalog for the RubyLLM provider.
    #
    # The catalog — not RubyLLM's bundled model registry — is Kuria's model
    # admission authority. An ID is admitted only when it is listed in the
    # verified Chat Completions manifest for one of the two accounts below
    # (OpenAI, OpenCode Go). Runtime admission additionally requires the ID to
    # be returned by that account's live `GET /v1/models` list, intersected
    # with the manifest; a live list alone never admits an ID, and a failed
    # live request never falls back to the manifest.
    #
    # Catalog request, shape, or credential failures fail closed with a clear
    # Catalog::Error; Kuria never silently falls back to a fixed list, the
    # RubyLLM registry, or the OpenCode Server.
    #
    # Kuria never calls `RubyLLM.models.refresh!`. RubyLLM's bundled registry
    # may be stale for current manifest IDs, so catalog-admitted models are
    # always passed to RubyLLM with `assume_model_exists: true`.
    #
    # Only Chat Completions models are catalogued; Responses, Anthropic
    # Messages, and audio/search-preview variants are intentionally absent.
    class Catalog
      Error = Class.new(Provider::RubyLlm::Error)

      # Bounded catalog transport. A live model-list lookup is a single bounded
      # attempt: open/read timeouts are explicit and finite so a slow or hung
      # endpoint can never hold an admission cycle open indefinitely.
      #
      # No Faraday retry middleware is installed on this connection (and no
      # retry options are passed), so a failed lookup is never repeated behind
      # the caller's back. Retryability is only reported in the structured error
      # details for callers that own retry policy.
      CATALOG_OPEN_TIMEOUT_SECONDS = 5
      CATALOG_READ_TIMEOUT_SECONDS = 30

      ACCOUNTS = {
        openai: {
          display_name: "OpenAI",
          prefix: "openai/",
          api_base: OPENAI_BASE_URL,
          credential_source: "OPENAI_API_KEY",
          billing_account: "openai",
          ruby_llm_provider: :openai,
          shutdown_filtering: true,
          manifest: %w[
            gpt-6-astra
            gpt-5.6-sol
            gpt-5.6-terra
            gpt-5.6-luna
            gpt-5.5
            gpt-5.5-2026-04-23
            gpt-5.4
            gpt-5.4-mini
            gpt-5.4-nano
            gpt-5.4-mini-2026-03-17
            gpt-5.4-nano-2026-03-17
            gpt-5.3-chat-latest
            gpt-5.2
            gpt-5.2-2025-12-11
            gpt-5.2-chat-latest
            gpt-5.2-pro
            gpt-5.2-pro-2025-12-11
            gpt-5.1
            gpt-5.1-2025-11-13
            gpt-5.1-codex
            gpt-5.1-mini
            gpt-5.1-chat-latest
            gpt-5
            gpt-5-mini
            gpt-5-nano
            gpt-5-2025-08-07
            gpt-5-mini-2025-08-07
            gpt-5-nano-2025-08-07
            gpt-5-chat-latest
            gpt-4.1
            gpt-4.1-mini
            gpt-4.1-nano
            gpt-4.1-2025-04-14
            gpt-4.1-mini-2025-04-14
            gpt-4.1-nano-2025-04-14
            o4-mini
            o4-mini-2025-04-16
            o3
            o3-2025-04-16
            o3-mini
            o3-mini-2025-01-31
            o1
            o1-2024-12-17
            o1-preview
            o1-preview-2024-09-12
            o1-mini
            o1-mini-2024-09-12
            gpt-4o
            gpt-4o-2024-11-20
            gpt-4o-2024-08-06
            gpt-4o-2024-05-13
            chatgpt-4o-latest
            codex-mini-latest
            gpt-4o-mini
            gpt-4o-mini-2024-07-18
            gpt-4-turbo
            gpt-4-turbo-2024-04-09
            gpt-4-0125-preview
            gpt-4-turbo-preview
            gpt-4-1106-preview
            gpt-4-vision-preview
            gpt-4
            gpt-4-0314
            gpt-4-0613
            gpt-4-32k
            gpt-4-32k-0314
            gpt-4-32k-0613
            gpt-3.5-turbo
            gpt-3.5-turbo-16k
            gpt-3.5-turbo-0301
            gpt-3.5-turbo-0613
            gpt-3.5-turbo-1106
            gpt-3.5-turbo-0125
            gpt-3.5-turbo-16k-0613
          ].freeze
        }.freeze,
        opencode_go: {
          display_name: "OpenCode Go",
          prefix: "opencode_go/",
          api_base: OPENCODE_GO_BASE_URL,
          credential_source: "OPENCODE_GO_API_KEY",
          billing_account: "opencode_go",
          ruby_llm_provider: :openai,
          shutdown_filtering: false,
          manifest: %w[
            glm-5.3-flash
            glm-5.3
            glm-5.2
            glm-5.1
            kimi-k3
            kimi-k2.7-code
            kimi-k2.6
            longcat-2.0
            deepseek-v4.1-flash
            deepseek-v4-pro
            deepseek-v4-flash
            deepseek-v4-flash-vision-exp
            mimo-v2.5
            mimo-v2.5-pro
            hy4-preview
            hy3
            omen-alpha
          ].freeze
        }.freeze
      }.freeze

      MANIFEST = ACCOUNTS.flat_map { |account, config|
        config[:manifest].map { |model_id|
          [ "#{config[:prefix]}#{model_id}", {
            account: account,
            model_id: model_id,
            provider: config[:ruby_llm_provider],
            protocol: :chat_completions,
            api_base: config[:api_base],
            credential_source: config[:credential_source],
            billing_account: config[:billing_account],
            assume_model_exists: true
          }.freeze ]
        }
      }.to_h.freeze

      class << self
        # The immutable positive catalog: model reference => resolution
        # metadata. Every entry is a Chat Completions model documented for its
        # account, and every entry is passed to RubyLLM with
        # `assume_model_exists: true` because the catalog, not RubyLLM's
        # registry, is the admission gate.
        def manifest
          MANIFEST
        end

        def accounts
          ACCOUNTS.keys
        end

        # Static (manifest-only) membership. This is the source of truth for
        # what may ever be admitted; runtime admission additionally requires a
        # live list intersection (see instance methods).
        def admits?(reference)
          MANIFEST.key?(reference)
        end

        def metadata_for(reference)
          MANIFEST[reference]
        end

        def account_for(reference)
          account = ACCOUNTS.find { |_, config| reference.to_s.start_with?(config[:prefix]) }
          account&.first
        end

        # Resolve a provider API key for an account's credential identifier.
        # The environment takes precedence; when it is absent the key falls
        # back to encrypted Rails credentials keyed by the same identifier.
        # The key value is never logged, echoed, or persisted.
        def api_key_for(credential_source)
          ENV[credential_source].presence || Rails.application.credentials[credential_source].presence
        end

        def manifest_references(account)
          config = ACCOUNTS.fetch(account)
          config[:manifest].map { |model_id| "#{config[:prefix]}#{model_id}" }
        end
      end

      def initialize
        @available_references = {}
      end

      # Whether a reference is currently admitted: catalogued AND returned by
      # the account's live model list (shutdown-filtered for OpenAI). Raises
      # Catalog::Error on request/shape/credential failures — it never falls
      # back to the static manifest.
      def available?(reference)
        account = self.class.account_for(reference)
        return false if account.nil?

        available_references(account).include?(reference)
      end

      # Admitted references for an account: manifest ∩ live model list, minus
      # OpenAI models whose `shutdown_date` is in the past. Memoized per
      # instance so a single admission cycle performs one live request.
      def available_references(account)
        @available_references[account] ||= begin
          config = ACCOUNTS.fetch(account)
          live_by_id = live_model_entries(account).index_by { |entry| entry["id"] }

          admitted = config[:manifest].select { |model_id| live_by_id.key?(model_id) }

          if config[:shutdown_filtering]
            admitted = admitted.reject { |model_id| shutdown_passed?(live_by_id.fetch(model_id)) }
          end

          admitted.map { |model_id| "#{config[:prefix]}#{model_id}" }.freeze
        end
      end

      # Live-admitted records for selection surfaces: catalog metadata for
      # every admitted reference, in deterministic account → manifest order.
      # Raises Catalog::Error when a live model list request or its response
      # shape fails — callers must not fall back to the static manifest.
      def available_records
        ACCOUNTS.keys.flat_map { |account|
          available_references(account).map { |reference|
            MANIFEST.fetch(reference).merge(reference: reference)
          }
        }
      end

      private
        # Authenticated live model list for an account. OpenAI is
        # authenticated with its own key; the OpenCode Go Bearer key is sent
        # for forward compatibility even though the endpoint is currently
        # public/global. Both accounts use the OpenAI-compatible Chat
        # Completions protocol.
        def live_model_entries(account)
          config = ACCOUNTS.fetch(account)
          api_key = self.class.api_key_for(config[:credential_source])

          if api_key.blank?
            raise Error, "Missing #{config[:credential_source]} for the #{account} model catalog request. Set #{config[:credential_source]} to check live #{account} model availability."
          end

          connection = Faraday.new(
            url: config[:api_base],
            request: {
              open_timeout: CATALOG_OPEN_TIMEOUT_SECONDS,
              timeout: CATALOG_READ_TIMEOUT_SECONDS
            }
          ) do |f|
            f.request :json
            f.response :json
            f.response :raise_error
            f.headers["Accept"] = "application/json"
            f.headers["Authorization"] = "Bearer #{api_key}"
          end

          body = connection.get("#{config[:api_base]}/models").body
          entries = body.is_a?(Hash) ? body["data"] : nil

          unless entries.is_a?(Array) && entries.all? { |entry| entry.is_a?(Hash) && entry["id"].is_a?(String) && entry["id"].present? }
            raise Error.new(
              "Unexpected model catalog response shape for account '#{account}': expected a JSON object with a 'data' array of models carrying string 'id' values.",
              details: {
                provider_reference: account.to_s,
                account: account,
                error_class: Error.name,
                retryable: false,
                http_status: nil
              }
            )
          end

          entries
        rescue Faraday::Error => e
          raise Error.new(
            "Model catalog request for account '#{account}' failed: #{e.class.name.split('::').last}.",
            details: {
              provider_reference: account.to_s,
              account: account,
              error_class: e.class.name,
              retryable: retryable_catalog_failure?(e),
              http_status: e.response_status
            }
          )
        end

        # Transport timeouts/connection failures and provider throttling or
        # outages are retryable; authentication, malformed payloads, and shape
        # failures are not. The catalog itself never retries a lookup.
        def retryable_catalog_failure?(error)
          return true if error.is_a?(Faraday::TimeoutError) || error.is_a?(Faraday::ConnectionFailed)

          status = error.response_status
          status == 408 || status == 429 || (500..599).cover?(status)
        end

        def shutdown_passed?(entry)
          raw = entry["shutdown_date"]
          return false if raw.blank?

          shutdown_date = parse_shutdown_date(raw)
          return false if shutdown_date.nil?

          shutdown_date < Date.current
        end

        def parse_shutdown_date(raw)
          Date.iso8601(raw.to_s)
        rescue ArgumentError, TypeError
          begin
            Date.parse(raw.to_s)
          rescue ArgumentError, TypeError
            nil
          end
        end
    end
  end
end
