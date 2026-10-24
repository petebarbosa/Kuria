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
  # Optional provider-neutral server-bound conversation identifier. Callers
  # pass the persisted conversation id (for example Chat.id); it is never
  # taken from model output, a prompt, or a provider-supplied session. The
  # RubyLLM provider uses it only to derive an opaque Go session token, so the
  # same conversation keeps the same session across provider instances.
  # Omission leaves each standalone request independent.
  def chat_response(prompt, model:, instructions: nil, functions: [], function_results: [], streamer: nil, previous_response_id: nil, history: [], conversation_id: nil)
    raise NotImplementedError, "Subclasses must implement #chat_response"
  end

  MerchantSuggestion = Data.define(:merchant_id, :confidence, :rationale)

  def suggest_merchant(raw_name:, normalized_name:, user_merchants:, model:)
    raise NotImplementedError, "Subclasses must implement #suggest_merchant"
  end
end
