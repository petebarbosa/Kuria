require "digest"
require "securerandom"

class Provider::RubyLlm < Provider
  include LlmConcept

  Error = Class.new(Provider::Error)

  OPENAI_BASE_URL = "https://api.openai.com/v1".freeze
  # Official OpenCode Go endpoints. The Go inference service exposes its live
  # model list at /inference/go/v1/models, while its OpenAI-compatible chat
  # API lives at /inference/go/openai/v1 (chat completions are posted to
  # /inference/go/openai/v1/chat/completions). The legacy /zen/go/v1 paths are
  # intentionally not used.
  OPENCODE_GO_BASE_URL = "https://opencode.ai/inference/go/v1".freeze
  OPENCODE_GO_CHAT_BASE_URL = "https://opencode.ai/inference/go/openai/v1".freeze
  OPENCODE_GO_MODELS_URL = "#{OPENCODE_GO_BASE_URL}/models".freeze
  OPENCODE_GO_SESSION_HEADER = "x-opencode-session".freeze
  OPENCODE_GO_SESSION_PREFIX = "ses_".freeze
  # Hash namespace for server-bound Chat identifiers. Including a fixed
  # namespace keeps the derived token scoped to this use; the raw identifier
  # never leaves the process.
  OPENCODE_GO_CONVERSATION_SESSION_NAMESPACE = "kuria:opencode_go:conversation".freeze
  # Go requires each client to identify itself instead of presenting a generic
  # HTTP-library or SDK user agent.
  OPENCODE_GO_USER_AGENT = "Kuria/1.0".freeze

  SUPPORTED_PROVIDER_REFERENCES = %w[openai opencode_go].freeze

  # RubyLLM custom provider for the official OpenCode Go OpenAI-compatible
  # Chat Completions API. A dedicated provider (rather than reusing :openai)
  # gives Go authoritative request headers: RubyLLM merges provider headers
  # after chat-level headers, so this is the stable 2.1.1 seam that can set a
  # client User-Agent and the required session header without affecting
  # OpenAI. It exposes Chat Completions only; Responses/Anthropic/Gemini
  # transports are never registered for Go. The session id comes from the
  # per-call context (derived from the server-bound conversation), with an
  # opaque per-instance fallback, and is never derived from model output.
  class OpenCodeGoProvider < RubyLLM::Provider
    protocol :chat_completions, RubyLLM::Protocols::ChatCompletions

    def api_base
      @config.openai_api_base || OPENCODE_GO_CHAT_BASE_URL
    end

    def headers
      {
        "Authorization" => "Bearer #{@config.openai_api_key}",
        OPENCODE_GO_SESSION_HEADER => @config.opencode_go_session_id.presence || session_id,
        "User-Agent" => OPENCODE_GO_USER_AGENT
      }.compact
    end

    def session_id
      @session_id ||= Provider::RubyLlm.request_session_id
    end

    def self.configuration_options
      %i[opencode_go_session_id]
    end

    def self.configuration_requirements
      %i[openai_api_key]
    end

    def self.assume_models_exist?
      true
    end
  end

  RubyLLM::Provider.register :opencode_go, OpenCodeGoProvider

  # Legacy structured-output enrichment guard: the workflows this provider
  # replaces cap a single request at 25 transactions. Preserved so an
  # over-sized enrichment batch fails closed instead of silently growing.
  MAX_ENRICHMENT_TRANSACTIONS = 25

  # Fixed per-response tool-call budget. A response that requests more calls
  # than this is audited in full and rejected before any of its calls execute.
  MAX_TOOL_CALLS_PER_RESPONSE = 5

  # Caller-supplied history is plain provider-neutral data. Only these roles
  # are understood; unknown roles fail closed rather than being dropped.
  HISTORY_ROLES = %w[user assistant system tool].freeze

  # Fixed audit reasons. The raw model payload is kept only in audit storage
  # (the caller's persistence callback), never in these messages or logs.
  TOOL_CALL_BUDGET_EXCEEDED_ERROR = "Tool call was not executed because the response exceeded the tool-call limit.".freeze
  MALFORMED_TOOL_CALL_ARGUMENTS_ERROR = "Tool call was not executed because the model returned malformed arguments.".freeze
  MALFORMED_TOOL_CALL_ENVELOPE_ERROR = "Tool call was not executed because the model returned a structurally malformed tool call.".freeze
  INVALID_STREAM_TOOL_CALL_ERROR = "Tool call was not executed because the model stream was malformed or incomplete.".freeze
  NON_OBJECT_TOOL_ARGUMENTS_ERROR = "Tool call was not executed because the model returned arguments that are not a JSON object.".freeze

  # Adapter-local bounded execution (#16). RubyLLM 2.1.1 defaults are
  # request_timeout: 300, max_retries: 3 (POSTs included), and
  # retry_max_interval: 30. Every per-call context gets an explicit, tighter
  # budget instead. request_timeout is the per-operation read timeout, not a
  # total wall-clock deadline: a request can still spend time connecting,
  # streaming accepted chunks, and waiting between a bounded number of retries.
  #
  # Streaming chats (chat_response always passes an ask block) MUST NOT retry:
  # a retried streaming request replays the already-partially-streamed answer
  # through the streamer. Non-streaming structured asks get at most one bounded
  # retry.
  #
  # retry_max_interval exists in RubyLLM 2.1.1 (default 30s); Kuria caps it so
  # the single structured retry stays tightly bounded.
  REQUEST_TIMEOUT_SECONDS = 120
  NON_STREAMING_MAX_RETRIES = 1
  STREAMING_MAX_RETRIES = 0
  RETRY_INTERVAL_SECONDS = 0.5
  RETRY_MAX_INTERVAL_SECONDS = 2
  RETRY_BACKOFF_FACTOR = 2
  RETRY_INTERVAL_RANDOMNESS = 0.5

  class << self
    # An opaque, non-identifying Go request session id. Go uses it only for
    # routing/prompt-cache affinity; it is generated per provider instance (or
    # per standalone catalog), never derived from a model, prompt, user, or
    # credential, and is never logged by Kuria.
    def request_session_id
      "#{OPENCODE_GO_SESSION_PREFIX}#{SecureRandom.hex(16)}"
    end

    # Deterministic, opaque session id for a server-bound conversation
    # identifier (Chat.id). The same conversation therefore keeps the same Go
    # routing/prompt-cache session across fresh provider instances, while the
    # raw identifier and caller data never appear in the header. A blank
    # identifier (standalone call or enrichment) gets an independent generated
    # session instead.
    def conversation_session_id(conversation_id)
      return request_session_id if conversation_id.blank?

      digest = Digest::SHA256.hexdigest(
        "#{OPENCODE_GO_CONVERSATION_SESSION_NAMESPACE}:#{conversation_id}"
      )
      "#{OPENCODE_GO_SESSION_PREFIX}#{digest[0, 32]}"
    end

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

  def chat_response(prompt, model:, instructions: nil, functions: [], function_results: [], streamer: nil, previous_response_id: nil, tool: nil, audit_callback: nil, history: [], conversation_id: nil)
    with_provider_response(error_transformer: error_transformer_for(model)) do
      reference = resolve_reference(model)
      history_messages = normalize_history(history, model)
      session_id = conversation_id.present? && reference[:account] == :opencode_go ?
        self.class.conversation_session_id(conversation_id) : nil
      context = ruby_llm_context(reference, streaming: true, session_id: session_id)

      # The catalog is the admission authority: every admitted model is passed
      # with assume_model_exists: true (RubyLLM 2.1.1's bundled registry may be
      # stale for current manifest IDs and is never refreshed by Kuria).
      # The protocol is pinned so no provider can silently default to a
      # different transport.
      chat = context.chat(
        model: reference[:model_id],
        provider: reference[:provider],
        protocol: :chat_completions,
        assume_model_exists: reference[:assume_model_exists]
      )
      chat = chat.with_instructions(instructions) if instructions.present?

      if tool.present?
        chat = chat.with_tools(tool).with_tool_options(concurrency: false)
      end

      # Replay caller-supplied history before installing the live audit hooks:
      # add_message appends and coerces plain Hashes without executing tools or
      # firing after_message, so historical rounds never consume the current
      # request's audit budget. Current instructions are applied exactly once
      # above and are never re-applied after the replay.
      history_messages.each { |message| chat.add_message(message) }

      audit_state = { round: 0, call_count: 0, identity_by_call_id: {} }
      register_tool_audit_callbacks(chat, audit_callback, audit_state, model) if audit_callback.present?

      final_message = with_recovered_tool_calls(model, audit_callback, audit_state) do
        chat.ask(prompt) do |chunk|
          next if streamer.nil?

          text = chunk.respond_to?(:content) ? chunk.content : nil
          streamer.call(ChatStreamChunk.new(type: "output_text", data: text)) if text.present?
        end
      end

      if empty_completion?(final_message)
        raise Error, "RubyLLM returned an empty completion for model '#{model}'."
      end

      response = build_response(final_message, model)

      streamer.call(ChatStreamChunk.new(type: "response", data: response)) if streamer.present?
      response
    end
  end

  # Auto-categorization (#15) through RubyLLM structured output. The model
  # reference is explicit and travels in from the caller (the saved
  # Family#enrichment_model); there is no default, so a blank or unavailable
  # selection fails closed. The returned data are provider-independent
  # Provider::LlmConcept::AutoCategorization values — no RubyLLM object
  # escapes the adapter.
  def auto_categorize(transactions: [], user_categories: [], model:)
    with_provider_response(error_transformer: error_transformer_for(model)) do
      ensure_enrichment_transaction_limit!(transactions, "auto-categorize")

      categorizer = AutoCategorizer.new(transactions: transactions, user_categories: user_categories)
      final_message = structured_completion(
        model: model,
        instructions: categorizer.instructions,
        prompt: categorizer.prompt,
        schema: categorizer.schema
      )

      categorizer.build_results(final_message)
    end
  end

  # Merchant detection (#30) through RubyLLM structured output. The model
  # reference is explicit and travels in from the caller (the saved
  # Family#enrichment_model); there is no default, so a blank or unavailable
  # selection fails closed. The returned data are provider-independent
  # Provider::LlmConcept::AutoDetectedMerchant values — no RubyLLM object
  # escapes the adapter.
  def auto_detect_merchants(transactions: [], user_merchants: [], model:)
    with_provider_response(error_transformer: error_transformer_for(model)) do
      ensure_enrichment_transaction_limit!(transactions, "auto-detect merchants")

      detector = AutoMerchantDetector.new(transactions: transactions, user_merchants: user_merchants)
      final_message = structured_completion(
        model: model,
        instructions: detector.instructions,
        prompt: detector.prompt,
        schema: detector.schema
      )

      detector.build_results(final_message)
    end
  end

  # Merchant suggestion (#30) through RubyLLM structured output. The model
  # reference is explicit and travels in from the caller (the saved
  # Family#enrichment_model); there is no default, so a blank or unavailable
  # selection fails closed. The returned data is a provider-independent
  # Provider::LlmConcept::MerchantSuggestion — no RubyLLM object escapes the
  # adapter — and a missing merchant_id is a legitimate "no suggestion".
  def suggest_merchant(raw_name:, normalized_name:, user_merchants:, model:)
    with_provider_response(error_transformer: error_transformer_for(model)) do
      suggester = MerchantSuggester.new(
        raw_name: raw_name,
        normalized_name: normalized_name,
        user_merchants: user_merchants
      )
      final_message = structured_completion(
        model: model,
        instructions: suggester.instructions,
        prompt: suggester.prompt,
        schema: suggester.schema
      )

      suggester.build_result(final_message)
    end
  end

  private
    ChatMessage = Provider::LlmConcept::ChatMessage
    ChatStreamChunk = Provider::LlmConcept::ChatStreamChunk
    ChatResponse = Provider::LlmConcept::ChatResponse

    def catalog
      @catalog ||= Catalog.new(session_id: opencode_go_session_id)
    end

    # Stable for this provider instance so its live Go model-list lookups share
    # one opaque session. Chat and structured requests get their own
    # provider-instance session inside RubyLLM. A new provider instance gets a
    # fresh id.
    def opencode_go_session_id
      @opencode_go_session_id ||= self.class.request_session_id
    end

    # Validates caller-supplied provider-neutral history and translates each
    # entry into the plain attribute Hash RubyLLM's Chat#add_message accepts.
    # Only fresh copies are handed to the gem, so caller data is never mutated.
    # Unknown roles and malformed entries fail closed through the provider
    # envelope instead of being skipped or partially replayed.
    def normalize_history(history, model)
      return [] if history.nil?

      unless history.is_a?(Array)
        raise Error, "History must be an Array of message hashes for model '#{model}'."
      end

      history.map { |entry| normalize_history_entry(entry, model) }
    end

    def normalize_history_entry(entry, model)
      unless entry.is_a?(Hash)
        raise Error, "Each history entry must be a Hash for model '#{model}'."
      end

      attributes = entry.symbolize_keys
      role = attributes[:role].to_s

      unless HISTORY_ROLES.include?(role)
        raise Error, "Unsupported history role for model '#{model}'. Supported roles: #{HISTORY_ROLES.join(', ')}."
      end

      content = attributes[:content]

      unless content.nil? || content.is_a?(String)
        raise Error, "History content must be a String for model '#{model}'."
      end

      case role
      when "assistant"
        normalize_history_assistant(attributes, content, model)
      when "tool"
        normalize_history_tool_result(attributes, content, model)
      else
        if attributes[:tool_calls].present?
          raise Error, "Only assistant history may carry tool calls for model '#{model}'."
        end

        { role: role.to_sym, content: content&.dup }
      end
    end

    def normalize_history_assistant(attributes, content, model)
      message = { role: :assistant, content: content&.dup }
      raw_calls = attributes[:tool_calls]
      return message if raw_calls.nil?

      unless raw_calls.is_a?(Array)
        raise Error, "History tool_calls must be an Array for model '#{model}'."
      end

      calls = raw_calls.each_with_object({}) do |raw_call, calls_by_id|
        unless raw_call.is_a?(Hash)
          raise Error, "Each history tool call must be a Hash for model '#{model}'."
        end

        call = raw_call.symbolize_keys
        id = call[:id]
        name = call[:name]
        arguments = call[:arguments].nil? ? {} : call[:arguments]

        unless id.is_a?(String) && id.present?
          raise Error, "History tool call must carry an id for model '#{model}'."
        end

        unless name.is_a?(String) && name.present?
          raise Error, "History tool call must carry a name for model '#{model}'."
        end

        unless arguments.is_a?(Hash)
          raise Error, "History tool call arguments must be a Hash for model '#{model}'."
        end

        if calls_by_id.key?(id)
          raise Error, "History tool call ids must be unique for model '#{model}'."
        end

        calls_by_id[id.dup] = { id: id.dup, name: name.dup, arguments: arguments.deep_dup }
      end

      message.merge(tool_calls: calls)
    end

    def normalize_history_tool_result(attributes, content, model)
      tool_call_id = attributes[:tool_call_id]

      unless tool_call_id.is_a?(String) && tool_call_id.present?
        raise Error, "History tool result must carry a tool_call_id for model '#{model}'."
      end

      unless content.is_a?(String)
        raise Error, "History tool result content must be a String for model '#{model}'."
      end

      if attributes[:tool_calls].present?
        raise Error, "Only assistant history may carry tool calls for model '#{model}'."
      end

      { role: :tool, content: content.dup, tool_call_id: tool_call_id.dup }
    end

    # Audits every parsed tool call before RubyLLM dispatches it, and audits
    # each tool result as it is appended. Registering this on the assistant
    # message hook is deliberate: in RubyLLM 2.1.1 the hook fires after the
    # assistant response is parsed but before `run_tools` executes anything.
    # A persistence (or policy) failure raised from the callback therefore
    # prevents execution. Tool result messages correlate by their
    # tool_call_id; `after_tool_result` is not used because it carries no id.
    def register_tool_audit_callbacks(chat, audit_callback, state, model)
      chat.after_message do |message|
        case message.role.to_s
        when "assistant"
          next unless message.respond_to?(:tool_call?) && message.tool_call?

          state[:round] += 1
          round = state[:round]
          calls = message.tool_calls.values.each_with_index.map do |tool_call, index|
            {
              identity: "#{round}:#{index}",
              provider_call_id: tool_call.id,
              function_name: tool_call.name.presence || "unknown_tool",
              arguments: tool_call.arguments
            }
          end

          if state[:call_count] + calls.size > MAX_TOOL_CALLS_PER_RESPONSE
            audit_callback.call(
              type: :tool_calls, round: round, calls: calls,
              status: :not_executed, error: TOOL_CALL_BUDGET_EXCEEDED_ERROR
            )
            raise Error, "RubyLLM response for model '#{model}' exceeded the tool-call limit of #{MAX_TOOL_CALLS_PER_RESPONSE}."
          end

          state[:call_count] += calls.size
          valid_arguments = calls.all? { |call| call[:arguments].is_a?(Hash) }

          audit_callback.call(
            type: :tool_calls, round: round, calls: calls,
            status: valid_arguments ? :pending : :not_executed,
            error: valid_arguments ? nil : NON_OBJECT_TOOL_ARGUMENTS_ERROR
          )

          unless valid_arguments
            raise Error, "RubyLLM response for model '#{model}' returned tool arguments that are not a JSON object."
          end

          state[:identity_by_call_id] = calls.each_with_object({}) do |call, identities|
            identities[call[:provider_call_id]] = call[:identity] if call[:provider_call_id].present?
          end
        when "tool"
          identity = state[:identity_by_call_id][message.tool_call_id]
          next if identity.nil?

          audit_callback.call(
            type: :tool_result, round: state[:round], identity: identity,
            result: message.content.to_s
          )
        end
      end
    end

    # Recovers the raw tool-call fragments the request-local StreamingAdapter
    # observed when RubyLLM aborts before producing a message (and therefore
    # before any after_message hook), either on malformed JSON arguments or on
    # a structurally malformed envelope. All calls in the rejected batch are
    # audited as not executed, then the safe provider error is raised without
    # the raw payload.
    def with_recovered_tool_calls(model, audit_callback, state)
      recovered = []

      StreamingAdapter.collect_tool_calls(recovered) do
        yield
      end
    rescue RubyLLM::ToolCallParseError
      audit_recovered_tool_calls(recovered, audit_callback, state)
      raise Error, "RubyLLM returned malformed tool call arguments for model '#{model}'."
    rescue StreamingAdapter::MalformedToolCallError
      audit_recovered_tool_calls(
        recovered,
        audit_callback,
        state,
        error: MALFORMED_TOOL_CALL_ENVELOPE_ERROR
      )
      raise Error, "RubyLLM returned a structurally malformed tool call for model '#{model}'."
    rescue StreamingAdapter::InvalidStreamError
      audit_recovered_tool_calls(
        recovered,
        audit_callback,
        state,
        error: INVALID_STREAM_TOOL_CALL_ERROR
      )
      raise
    end

    def audit_recovered_tool_calls(recovered, audit_callback, state, error: MALFORMED_TOOL_CALL_ARGUMENTS_ERROR)
      return if audit_callback.nil?
      # A completed, parsed tool round increments the round counter and also
      # published its fragments. Only a batch beyond the parsed rounds belongs
      # to the malformed response that never reached after_message.
      return unless recovered.size > state[:round]

      batch = recovered.last
      calls = batch.is_a?(Hash) ? Array(batch[:calls]) : []
      return if calls.empty?

      round = state[:round] + 1
      entries = calls.each_with_index.map do |call, index|
        {
          identity: "#{round}:#{index}",
          provider_call_id: call[:id].presence,
          function_name: call[:name].presence || "unknown_tool",
          arguments: call[:raw_arguments].to_s
        }
      end

      audit_callback.call(
        type: :tool_calls, round: round, calls: entries,
        status: :not_executed, error: error
      )
    end

    # Isolated per-call RubyLLM context carrying the resolved account's key and
    # API base plus the adapter-local bounded execution budget. OpenAI keeps the
    # deployment's inherited organization/project identity. OpenCode Go uses the
    # dedicated :opencode_go provider with the same isolated credential/base,
    # and explicitly clears inherited organization/project headers so no
    # OpenAI billing identity can leak into a Go request.
    def ruby_llm_context(reference, streaming:, session_id: nil)
      RubyLLM.context do |config|
        config.openai_api_key = reference[:api_key]
        config.openai_api_base = reference[:api_base]

        config.faraday_adapter = StreamingAdapter
        # Disable RubyLLM instrumentation only on this copied request context:
        # tool events carry arguments/results and Rails' global instrumenter
        # forwards them to framework subscribers. The global config is untouched.
        config.instrumenter = nil
        config.request_timeout = REQUEST_TIMEOUT_SECONDS
        config.max_retries = streaming ? STREAMING_MAX_RETRIES : NON_STREAMING_MAX_RETRIES
        config.retry_interval = RETRY_INTERVAL_SECONDS
        config.retry_max_interval = RETRY_MAX_INTERVAL_SECONDS
        config.retry_backoff_factor = RETRY_BACKOFF_FACTOR
        config.retry_interval_randomness = RETRY_INTERVAL_RANDOMNESS

        if reference[:account] == :opencode_go
          config.opencode_go_session_id = session_id.presence || self.class.request_session_id
          config.openai_organization_id = nil
          config.openai_project_id = nil
        end
      end
    end

    # Runs a single non-streaming structured-output chat against the explicit
    # model reference and returns the final RubyLLM message. The caller's
    # helper normalizes its structured content (JSON text through the public
    # `Message#parsed` accessor) into provider-independent values; the RubyLLM
    # message itself never leaves the adapter.
    def structured_completion(model:, instructions:, prompt:, schema:)
      reference = resolve_reference(model)
      context = ruby_llm_context(reference, streaming: false)

      chat = context.chat(
        model: reference[:model_id],
        provider: reference[:provider],
        protocol: :chat_completions,
        assume_model_exists: reference[:assume_model_exists]
      )
      chat = chat.with_instructions(instructions) if instructions.present?
      chat = chat.with_schema(schema)

      chat.ask(prompt)
    end

    def ensure_enrichment_transaction_limit!(transactions, capability)
      return if transactions.size <= MAX_ENRICHMENT_TRANSACTIONS

      raise Error, "Too many transactions to #{capability}. Max is #{MAX_ENRICHMENT_TRANSACTIONS} per request."
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
      unless metadata[:protocol] == :chat_completions
        raise Error, "Unsupported protocol '#{metadata[:protocol]}' for model '#{model}'. RubyLLM only supports Chat Completions for this catalog; Responses, Anthropic Messages, and Gemini transports are not enabled."
      end

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

    def empty_completion?(message)
      content = message.respond_to?(:content) ? message.content : nil
      tool_calls = message.respond_to?(:tool_calls) ? message.tool_calls : nil

      content.blank? && tool_calls.blank?
    end

    def error_transformer_for(model)
      proc do |error|
        Error.new(error_message(error, model), details: error_details(error, model))
      end
    end

    # Structured transport details for a model failure. Catalog::Error carries
    # the original Faraday class, retryability, and HTTP status; only those
    # whitelisted keys are merged so catalog internals can never choose the
    # envelope's model or provider, which stay authoritative from the resolved
    # reference.
    def error_details(error, model)
      provider_reference = parse_reference(model)&.dig(:provider)
      details = {
        provider_reference: provider_reference,
        model: model,
        error_class: error.class.name,
        retryable: retryable?(error)
      }

      if error.is_a?(Catalog::Error) && error.details.is_a?(Hash)
        details.merge!(error.details.slice(:error_class, :retryable, :http_status))
        details[:provider_reference] = provider_reference
        details[:model] = model
      end

      details
    end

    def error_message(error, model)
      case error
      when Error
        error.message
      when StreamingAdapter::InvalidStreamError
        "RubyLLM model stream was malformed or incomplete for provider '#{provider_label(model)}'"
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
      when StreamingAdapter::InvalidStreamError
        true
      when RubyLLM::RateLimitError, RubyLLM::ServerError, RubyLLM::ServiceUnavailableError, RubyLLM::OverloadedError
        true
      when Faraday::TimeoutError, Faraday::ConnectionFailed
        true
      else
        false
      end
    end
end
