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
  # streamed after a reload. The thinking indicator is removed exactly once: as
  # soon as the first visible content arrives, or when the request ends without
  # content, whether it succeeds or fails.
  def respond_to(message)
    thinking_stopped = false
    stop_thinking_once = lambda do
      next if thinking_stopped

      thinking_stopped = true
      stop_thinking
    end

    llm = get_model_provider(message.ai_model)

    assistant_message = AssistantMessage.new(
      chat: chat,
      content: "",
      ai_model: message.ai_model
    )

    streamer = proc do |chunk|
      next unless chunk.type == "output_text"

      stop_thinking_once.call if assistant_message.content.blank?
      assistant_message.append_text!(chunk.data)
    end

    response = llm.chat_response(
      message.content,
      model: message.ai_model,
      instructions: instructions,
      streamer: streamer,
      previous_response_id: chat.opencode_session_id
    )

    unless response.success?
      raise response.error
    end

    completed = response.data

    stop_thinking_once.call
    finalize_assistant_message(assistant_message, completed) if completed
    persist_provider_response!(completed) if completed

    completed
  rescue => e
    stop_thinking_once.call
    chat.add_error(e)
  end

  private
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

    def persist_provider_response!(completed)
      id = completed_id(completed)
      return if id.blank?

      chat.update_latest_response!(id)
      chat.update!(opencode_session_id: id) if chat.opencode_session_id.blank?
    end

    def completed_text(completed)
      return "" unless completed.respond_to?(:messages)

      Array(completed.messages).map(&:output_text).join
    end

    def completed_id(completed)
      completed.respond_to?(:id) ? completed.id : nil
    end
end
