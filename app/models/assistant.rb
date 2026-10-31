class Assistant
  include Provided, Configurable, Broadcastable

  # Provider-neutral history cannot be reconstructed faithfully from a
  # completed owner whose audit rows are ambiguous or incomplete. This error is
  # deliberately generic: persisted arguments/results and financial details
  # must never leak through the chat error envelope.
  class HistoryReconstructionError < Provider::Error; end

  HISTORY_RECONSTRUCTION_ERROR_MESSAGE = "Conversation history could not be reconstructed safely.".freeze
  HISTORY_TOOL_CALL_ID_PREFIX = "history-tool-call-".freeze

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
    started_at = monotonic_time
    outcome = :error
    provider_telemetry_event = nil
    tool_outcome_by_identity = {}

    thinking_stopped = false
    stop_thinking_once = lambda do
      next if thinking_stopped

      thinking_stopped = true
      stop_thinking
    end

    audit_records = {}
    assistant_message = nil

    # Marks whether this attempt's message has been finalized from the
    # completed provider response. Until then any failure discards the
    # attempt's partial message; afterwards the reply is preserved even if a
    # later chat-level persistence step fails.
    finalized = false
    llm = get_model_provider(message.ai_model)

    # Snapshot the provider-neutral history before this attempt creates any
    # message or starts a provider request. Reconstruction failure must abort
    # the turn without touching existing messages and without leaving a
    # phantom attempt owner. Only RubyLLM accepts the history keyword.
    history = llm.is_a?(Provider::RubyLlm) ? history_for(message) : nil

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

    provider_options = {
      model: message.ai_model,
      instructions: instructions,
      streamer: streamer
    }

    # Tool binding and audit persistence are RubyLLM-only. The family and user
    # always come from the chat's authenticated user, never from the model or
    # Current.
    if llm.is_a?(Provider::RubyLlm)
      family = chat.user.family
      provider_options[:conversation_id] = chat.id
      provider_options[:history] = history
      provider_options[:tool] = [
        Provider::RubyLlm::FinancialTool::GetAccounts.new(family),
        Provider::RubyLlm::FinancialTool::ProposeTransaction.new(
          family: family,
          user: chat.user,
          message_id: message.id
        )
      ]
      provider_options[:audit_callback] = audit_callback_for(
        assistant_message,
        audit_records,
        tool_outcome_by_identity
      )
      provider_options[:telemetry_callback] = proc { |event| provider_telemetry_event = event }
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
    resolve_pending_tool_outcomes!(tool_outcome_by_identity, :rejected)
    persist_provider_response!(completed)

    outcome = :success
    completed
  rescue => e
    stop_thinking_once.call
    fail_or_discard_attempted_assistant_message!(
      assistant_message,
      finalized: finalized,
      audit_records: audit_records
    )
    chat.add_error(e)
  ensure
    resolve_pending_tool_outcomes!(tool_outcome_by_identity, :failed) if outcome == :error
    emit_request_telemetry(
      message: message,
      provider_event: provider_telemetry_event,
      tool_outcome_by_identity: tool_outcome_by_identity,
      outcome: outcome,
      started_at: started_at
    )
  end

  private
    PENDING_TOOL_RESULT = { "status" => "pending" }.freeze
    NOT_EXECUTED_TOOL_RESULT = { "error" => "Tool call was not executed." }.freeze
    INTERRUPTED_TOOL_RESULT = {
      "error" => "Tool execution outcome is unknown because the response was interrupted."
    }.freeze
    TOOL_RESULT_TOO_LARGE_RESULT = { "error" => "Tool result too large to audit." }.freeze
    MAX_AUDIT_RESULT_BYTES = 100 * 1024

    # Persists the single audit owner for this attempt before any tool runs,
    # and records each provider tool event against it. Tool calls receive a
    # round-local identity (the provider call id can repeat across rounds) and
    # keep their actual provider id separately. Raw malformed arguments are
    # accepted only into `function_arguments`, never into errors or logs.
    def audit_callback_for(assistant_message, audit_records, tool_outcome_by_identity)
      proc do |event|
        case event[:type]
        when :tool_calls
          assistant_message.save! unless assistant_message.persisted?
          status = event[:status] == :not_executed ? :rejected : :pending

          Array(event[:calls]).each do |call|
            tool_outcome_by_identity[call[:identity]] = status
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
          identity = event[:identity]
          result = normalize_audit_result(event[:result])
          tool_outcome_by_identity[identity] = tool_outcome_for_result(result) if identity.present?

          record = audit_records[identity]
          next if record.nil?

          record.update!(function_result: result)
        end
      end
    end

    def tool_outcome_for_result(result)
      failed = result.is_a?(Hash) && (result["error"].present? || result[:error].present?)
      failed ? :failed : :succeeded
    end

    def resolve_pending_tool_outcomes!(tool_outcome_by_identity, resolved_outcome)
      tool_outcome_by_identity.each do |identity, outcome|
        tool_outcome_by_identity[identity] = resolved_outcome if outcome == :pending
      end
    end

    def summarize_tool_outcomes(tool_outcome_by_identity)
      tool_outcome_by_identity.each_value.with_object({ succeeded: 0, rejected: 0, failed: 0 }) do |outcome, counts|
        key = %i[succeeded rejected failed].include?(outcome) ? outcome : :failed
        counts[key] += 1
      end
    end

    def emit_request_telemetry(message:, provider_event:, tool_outcome_by_identity:, outcome:, started_at:)
      AssistantTelemetry.record(
        message_id: message&.id,
        chat_id: chat&.id,
        provider_event: provider_event,
        tool_outcomes: summarize_tool_outcomes(tool_outcome_by_identity),
        outcome: outcome,
        latency_ms: elapsed_ms(started_at)
      )
    rescue StandardError
      nil
    end

    def elapsed_ms(started_at)
      ((monotonic_time - started_at) * 1000).round
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def audit_tool_result_for(event)
      return PENDING_TOOL_RESULT unless event[:status] == :not_executed

      { "error" => event[:error].presence || NOT_EXECUTED_TOOL_RESULT["error"] }
    end

    def normalize_audit_result(result)
      text = result.to_s
      return TOOL_RESULT_TOO_LARGE_RESULT if text.bytesize > MAX_AUDIT_RESULT_BYTES

      parsed = JSON.parse(text)
      return parsed if parsed.is_a?(Hash) && parsed.present?
      return { "value" => parsed } if parsed.present?

      { "raw" => text }
    rescue JSON::ParserError
      { "raw" => text }
    end

    # Builds a provider-neutral snapshot of this chat's persisted conversation
    # strictly before +message+. The snapshot uses chat.messages directly (not
    # the debug-dependent conversation view), keeps a deterministic local
    # (created_at, id) order, and never includes the current message or any
    # later row — including rows from a previous failed retry attempt.
    #
    # Only user messages, non-debug Developer messages, and completed
    # non-reasoning assistant answers participate. A completed owner's audit
    # rows are flattened into one assistant tool-request turn per numeric
    # round, immediately followed by that round's serialized results, and then
    # the owner's final answer once. Ambiguous or incomplete audit provenance
    # fails closed rather than silently omitting a historical tool block.
    def history_for(message)
      target = chat.messages.find_by(id: message.id)
      raise_history_reconstruction_error if target.nil?

      earlier_messages = chat.messages
        .where(
          "(messages.created_at < :created_at) OR " \
          "(messages.created_at = :created_at AND messages.id < :id)",
          created_at: target.created_at,
          id: target.id
        )
        .order(:created_at, :id)

      earlier_messages.each_with_object([]) do |historical, entries|
        case historical
        when UserMessage
          entries << { role: "user", content: historical.content }
        when DeveloperMessage
          next if historical.debug? || duplicate_guardrails?(historical)

          entries << { role: "system", content: historical.content }
        when AssistantMessage
          entries.concat(assistant_history_entries(historical))
        else
          raise_history_reconstruction_error
        end
      end
    end

    def duplicate_guardrails?(developer_message)
      instructions.present? && developer_message.content == instructions
    end

    def assistant_history_entries(message)
      return [] unless message.status == "complete"
      return [] if message.reasoning?
      raise_history_reconstruction_error unless message.content.is_a?(String)

      entries = tool_history_entries(message)
      entries << { role: "assistant", content: message.content }
      entries
    end

    def tool_history_entries(message)
      calls = message.tool_calls.order(:created_at, :id).to_a
      return [] if calls.empty?

      grouped_history_tool_calls(calls).flat_map do |_round, round_calls|
        round_calls.each { |call| validate_history_tool_call!(call) }

        tool_calls = round_calls.map { |call| history_tool_call(call) }
        results = round_calls.map { |call| history_tool_result(call) }

        [ { role: "assistant", content: nil, tool_calls: tool_calls } ] + results
      end
    end

    def grouped_history_tool_calls(calls)
      grouped = Hash.new { |hash, round| hash[round] = [] }
      seen_identities = {}

      calls.each do |call|
        round, index = history_tool_round_and_index(call)
        identity = [ round, index ]
        raise_history_reconstruction_error if seen_identities.key?(identity)

        seen_identities[identity] = true
        grouped[round] << [ index, call ]
      end

      rounds = grouped.keys.sort
      raise_history_reconstruction_error unless rounds == (1..rounds.size).to_a

      rounds.each_with_object({}) do |round, ordered|
        calls_by_index = grouped.fetch(round).sort_by { |index, _call| index }

        indexes = calls_by_index.map { |index, _call| index }
        raise_history_reconstruction_error unless indexes == (0...indexes.size).to_a

        ordered[round] = calls_by_index.map { |_index, call| call }
      end
    end

    def history_tool_round_and_index(call)
      match = /\A(\d+):(\d+)\z/.match(call.provider_id.to_s)
      raise_history_reconstruction_error unless match

      round = Integer(match[1], 10)
      index = Integer(match[2], 10)
      raise_history_reconstruction_error if round < 1

      [ round, index ]
    end

    def validate_history_tool_call!(call)
      raise_history_reconstruction_error unless call.is_a?(ToolCall::Function)
      raise_history_reconstruction_error unless call.provider_call_id.is_a?(String) && call.provider_call_id.present?
      raise_history_reconstruction_error unless call.function_name.is_a?(String) && call.function_name.present?
      raise_history_reconstruction_error unless call.function_arguments.is_a?(Hash)

      result = call.function_result
      raise_history_reconstruction_error unless result.is_a?(Hash) && result.present?
      raise_history_reconstruction_error if result == PENDING_TOOL_RESULT
      raise_history_reconstruction_error if result == TOOL_RESULT_TOO_LARGE_RESULT
      raise_history_reconstruction_error if result == INTERRUPTED_TOOL_RESULT
    end

    def history_tool_call(call)
      {
        id: history_tool_call_id(call),
        name: call.function_name,
        arguments: call.function_arguments
      }
    end

    def history_tool_result(call)
      {
        role: "tool",
        tool_call_id: history_tool_call_id(call),
        content: call.function_result.to_json
      }
    end

    # A provider call id may repeat across rounds or later calls and RubyLLM
    # treats an answered id globally. History therefore uses an id derived from
    # the unique audit row, never the original provider id; saved rows and the
    # live round keep their original ids untouched.
    def history_tool_call_id(call)
      "#{HISTORY_TOOL_CALL_ID_PREFIX}#{call.id}"
    end

    def raise_history_reconstruction_error
      raise HistoryReconstructionError, HISTORY_RECONSTRUCTION_ERROR_MESSAGE
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

    def persist_provider_response!(completed)
      id = completed_id(completed)
      return if id.blank?

      chat.update_latest_response!(id)
    end

    def completed_text(completed)
      return "" unless completed.respond_to?(:messages)

      Array(completed.messages).map(&:output_text).join
    end

    def completed_id(completed)
      completed.respond_to?(:id) ? completed.id : nil
    end
end
