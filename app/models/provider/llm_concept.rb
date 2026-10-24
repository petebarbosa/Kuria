module Provider::LlmConcept
  extend ActiveSupport::Concern

  # Capability interface for LLM enrichment. Callers must pass an explicit
  # canonical model reference (e.g. "openai/gpt-5-nano"); there is no default
  # model, so an unavailable selection fails closed rather than substituting
  # another provider or model.
  AutoCategorization = Data.define(:transaction_id, :category_name)

  def auto_categorize(transactions: [], user_categories: [], model:)
    raise NotImplementedError, "Subclasses must implement #auto_categorize"
  end

  AutoDetectedMerchant = Data.define(:transaction_id, :business_name, :business_url)

  def auto_detect_merchants(transactions: [], user_merchants: [], model:)
    raise NotImplementedError, "Subclasses must implement #auto_detect_merchants"
  end

  ChatMessage = Data.define(:id, :output_text)
  ChatStreamChunk = Data.define(:type, :data)
  ChatResponse = Data.define(:id, :model, :messages, :function_requests)
  ChatFunctionRequest = Data.define(:id, :call_id, :function_name, :function_args)

  # Optional provider-neutral conversation history supplied by the caller,
  # excluding the current prompt. Entries are plain Hashes with a String or
  # Symbol +role+ of "user", "assistant", "system", or "tool":
  #
  #   { role: "user", content: "..." }
  #   { role: "assistant", content: "...",
  #     tool_calls: [ { id: "call-1", name: "get_accounts", arguments: { "family_id" => 1 } } ] }
  #   { role: "tool", tool_call_id: "call-1", content: "{\"accounts\":[]}" }
  #   { role: "system", content: "..." }
  #
  # Providers translate these into their own message objects internally; no
  # provider object is accepted or returned. Callers must not mutate the
  # supplied entries. Omitting +history+ (or passing an empty Array) keeps the
  # existing single-prompt behavior.
  #
  # Provider::RubyLlm additionally accepts an optional +telemetry_callback:+
  # keyword on #chat_response. It receives exactly one frozen, allowlisted
  # Hash per request (success or error):
  #
  #   {
  #     event: :ruby_llm_request,
  #     outcome: :success | :error,
  #     provider: "openai" | "opencode_go",
  #     model: "openai/gpt-5-nano",
  #     latency_ms: Integer,
  #     retry_count: Integer,
  #     usage: {
  #       input_tokens:, output_tokens:, cache_read_tokens:,
  #       cache_write_tokens:, reasoning_tokens:
  #     },
  #     estimated_cost: { usd:, known:, source:, reason: },
  #     error_class: String | nil,
  #     error_retryable: true | false | nil
  #   }
  #
  # Token counts are nil when the provider did not report them. A nil +usd+
  # with +known: false+ means unknown pricing, never zero. Prompt text, tool
  # arguments/results, message content, provider response bodies, API keys,
  # and authorization data are never included. Callback exceptions are
  # swallowed and never change the provider response or error handling.
  def chat_response(prompt, model:, instructions: nil, functions: [], function_results: [], streamer: nil, previous_response_id: nil, history: [])
    raise NotImplementedError, "Subclasses must implement #chat_response"
  end

  MerchantSuggestion = Data.define(:merchant_id, :confidence, :rationale)

  def suggest_merchant(raw_name:, normalized_name:, user_merchants:, model:)
    raise NotImplementedError, "Subclasses must implement #suggest_merchant"
  end
end
