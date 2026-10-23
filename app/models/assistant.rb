class Assistant
  include Provided, Configurable, Broadcastable

  attr_reader :chat, :instructions

  class << self
    def for_chat(chat)
      config = config_for(chat)
      new(chat, instructions: config[:instructions])
    end
  end

  def initialize(chat, instructions: nil)
    @chat = chat
    @instructions = instructions
  end

  # Streams a provider response through the chat. Provider chunks are appended
  # to one AssistantMessage in provider order and broadcast as they arrive, so
  # the visible content is never reordered or duplicated. On success that same
  # message is finalized from the completed provider response — its content and
  # provider metadata come from the completed message, not an intermediate
  # chunk — leaving exactly one persisted AssistantMessage that matches what was
  # streamed after a reload. On failure the chunks that already reached the
  # client are rolled back: this attempt's persisted-but-unfinished
  # AssistantMessage is destroyed and its partial content is removed from the
  # stream, so the chat stays retryable and no phantom answer ghosts the turn.
  # A reply that was already finalized is never discarded, even if a later
  # persistence step fails. The thinking indicator is removed exactly once: as
  # soon as the first visible content arrives, or when the request ends without
  # content, whether it succeeds or fails.
  def respond_to(message)
    thinking_stopped = false
    stop_thinking_once = lambda do
      next if thinking_stopped

      thinking_stopped = true
      stop_thinking
    end

    audit_records = {}
    assistant_message = nil
    llm = get_model_provider(message.ai_model)

    assistant_message = AssistantMessage.new(
      chat: chat,
      content: "",
      ai_model: message.ai_model,
      status: :pending
    )

    streamer = proc do |chunk|
      next unless chunk.type == "output_text"

      stop_thinking_once.call if assistant_message.content.blank?
      assistant_message.append_text!(chunk.data)
    end

    # Marks whether this attempt's message has been finalized from the
    # completed provider response. Until then any failure discards the
    # attempt's partial message; afterwards the reply is preserved even if a
    # later chat-level persistence step fails.
    finalized = false

    provider_options = {
      model: message.ai_model,
      instructions: instructions,
      streamer: streamer,
      previous_response_id: legacy_opencode_session_id(llm)
    }

    # Tool binding and audit persistence are RubyLLM-only. The legacy
    # provider keeps its existing call contract, and the family always comes
    # from the chat's authenticated user, never from the model or Current.
    if llm.is_a?(Provider::RubyLlm)
      provider_options[:tool] = Provider::RubyLlm::FinancialTool::GetAccounts.new(chat.user.family)
      provider_options[:audit_callback] = audit_callback_for(assistant_message, audit_records)
    end

    response = llm.chat_response(message.content, **provider_options)

    unless response.success?
      raise response.error
    end

    completed = response.data

    # A successful provider response that carries no completed message is not a
    # success for this chat: there is nothing to finalize or persist, so fail
    # closed through the same error path rather than returning a false success.
    raise Provider::Error, "#{llm.class.name} returned success without a completed response" if completed.nil?

    stop_thinking_once.call
    finalize_assistant_message(assistant_message, completed)
    finalized = true
    close_outstanding_audit_records!(audit_records, fallback: NOT_EXECUTED_TOOL_RESULT)
    persist_provider_response!(completed, provider: llm)

    completed
  rescue => e
    stop_thinking_once.call
    fail_or_discard_attempted_assistant_message!(
      assistant_message,
      finalized: finalized,
      audit_records: audit_records
    )
    chat.add_error(e)
  end

  private
    PENDING_TOOL_RESULT = { "status" => "pending" }.freeze
    NOT_EXECUTED_TOOL_RESULT = { "error" => "Tool call was not executed." }.freeze
    INTERRUPTED_TOOL_RESULT = {
      "error" => "Tool execution outcome is unknown because the response was interrupted."
    }.freeze
    MAX_AUDIT_RESULT_BYTES = 100 * 1024

    # Persists the single audit owner for this attempt before any tool runs,
    # and records each provider tool event against it. Tool calls receive a
    # round-local identity (the provider call id can repeat across rounds) and
    # keep their actual provider id separately. Raw malformed arguments are
    # accepted only into `function_arguments`, never into errors or logs.
    def audit_callback_for(assistant_message, audit_records)
      proc do |event|
        case event[:type]
        when :tool_calls
          assistant_message.save! unless assistant_message.persisted?
          Array(event[:calls]).each do |call|
            audit_records[call[:identity]] = ToolCall::Function.create!(
              message: assistant_message,
              provider_id: call[:identity],
              provider_call_id: call[:provider_call_id],
              function_name: call[:function_name].presence || "unknown_tool",
              function_arguments: call[:arguments],
              function_result: audit_tool_result_for(event)
            )
          end
        when :tool_result
          record = audit_records[event[:identity]]
          next if record.nil?

          record.update!(function_result: normalize_audit_result(event[:result]))
        end
      end
    end

    def audit_tool_result_for(event)
      return PENDING_TOOL_RESULT unless event[:status] == :not_executed

      { "error" => event[:error].presence || NOT_EXECUTED_TOOL_RESULT["error"] }
    end

    def normalize_audit_result(result)
      text = result.to_s
      return { "error" => "Tool result too large to audit." } if text.bytesize > MAX_AUDIT_RESULT_BYTES

      parsed = JSON.parse(text)
      return parsed if parsed.is_a?(Hash) && parsed.present?
      return { "value" => parsed } if parsed.present?

      { "raw" => text }
    rescue JSON::ParserError
      { "raw" => text }
    end

    # Completes the single AssistantMessage from the finished provider response:
    # content and the provider response id are taken from the completed message,
    # never from a partial streaming chunk.
    def finalize_assistant_message(assistant_message, completed)
      content = completed_text(completed)
      assistant_message.content = content if content.present?
      assistant_message.provider_id = completed.id if completed_id(completed).present?
      assistant_message.status = :complete
      assistant_message.save!
    end

    # A failed attempt with durable tool audits keeps its hidden audit owner so
    # the calls and their outcomes survive for retry/diagnostics. Any partial
    # visible content is removed from the stream and cleared, outstanding calls
    # are closed with the interrupted/unknown outcome, and the owner is marked
    # failed (invisible). Attempts that never audited a call keep the original
    # destroy semantics.
    def fail_or_discard_attempted_assistant_message!(assistant_message, finalized:, audit_records:)
      return if finalized || !assistant_message&.persisted?

      if audit_records.any?
        fail_audited_attempt!(assistant_message, audit_records)
      else
        discard_attempted_assistant_message!(assistant_message, finalized: false)
      end
    end

    def fail_audited_attempt!(assistant_message, audit_records)
      if assistant_message.content.present?
        begin
          assistant_message.broadcast_remove_to chat
        rescue => e
          Rails.logger.warn("Assistant audit message remove broadcast failed: #{e.class}")
        end
      end

      close_outstanding_audit_records!(audit_records, fallback: INTERRUPTED_TOOL_RESULT)
      assistant_message.update!(content: "", status: :failed)
    end

    # A successful response can still leave a call without a result when the
    # provider never dispatched it (for example, a call id already answered in
    # an earlier round). Close those audits as not executed rather than leaving
    # a misleading pending record. Failure cleanup passes the interrupted
    # outcome instead, because execution may already have happened before the
    # provider failed and its result could not be recorded.
    def close_outstanding_audit_records!(audit_records, fallback:)
      audit_records.each_value do |record|
        next unless record.persisted?
        next unless record.function_result == PENDING_TOOL_RESULT

        record.update!(function_result: fallback)
      end
    end

    # A provider failure after partial chunks were streamed leaves this
    # attempt's AssistantMessage persisted and blocking
    # `Chat#needs_assistant_response?` (the last conversation message would
    # otherwise look like an assistant reply, so the retry gate no-ops).
    # Discard exactly this attempt's message — never a historical one, and
    # never one whose finalization already succeeded — and remove the partial
    # the client received through the same broadcast mechanism that painted
    # it (Message only broadcasts on create/update, so the removal is
    # broadcast explicitly here). Nothing needs discarding when the message
    # was never built or never persisted (e.g. the provider registry rejected
    # the reference before any chunk arrived).
    def discard_attempted_assistant_message!(assistant_message, finalized:)
      return if finalized || !assistant_message&.persisted?

      # The removal broadcast is a best-effort UI update: the persisted row is
      # the source of truth, so a broadcast failure must neither keep the
      # partial message in the chat nor mask the provider error this attempt is
      # already handling.
      begin
        assistant_message.broadcast_remove_to chat
      rescue => e
        Rails.logger.warn("Assistant message remove broadcast failed: #{e.class}")
      end

      assistant_message.destroy!
    end

    def persist_provider_response!(completed, provider:)
      id = completed_id(completed)
      return if id.blank?

      chat.update_latest_response!(id)
      return unless legacy_opencode_provider?(provider)
      return if chat.opencode_session_id.present?

      chat.update!(opencode_session_id: id)
    end

    # The legacy OpenCode provider threads its session id through
    # `previous_response_id`. RubyLLM owns its own conversation state, so a
    # legacy OpenCode session id must never cross into a RubyLLM request. The
    # provider the registry resolved decides this — no model-reference parsing.
    def legacy_opencode_session_id(provider)
      chat.opencode_session_id if legacy_opencode_provider?(provider)
    end

    def legacy_opencode_provider?(provider)
      provider.is_a?(Provider::Opencode)
    end

    def completed_text(completed)
      return "" unless completed.respond_to?(:messages)

      Array(completed.messages).map(&:output_text).join
    end

    def completed_id(completed)
      completed.respond_to?(:id) ? completed.id : nil
    end
end
