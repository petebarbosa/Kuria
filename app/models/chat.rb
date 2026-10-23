class Chat < ApplicationRecord
  include Debuggable

  belongs_to :user

  has_one :viewer, class_name: "User", foreign_key: :last_viewed_chat_id, dependent: :nullify # "Last chat user has viewed"
  has_many :messages, dependent: :destroy

  validates :title, presence: true
  validate :validate_ai_model, if: -> { ai_model_changed? && ai_model.present? }

  scope :ordered, -> { order(created_at: :desc) }

  class << self
    # Creates a chat with its initial user message, snapshotting the caller's
    # explicit model onto both the chat and the message. There is no automatic
    # or deployment default: a blank model fails the UserMessage presence
    # validation rather than being substituted.
    def start!(prompt, model: nil)
      transaction do
        chat = create!(
          title: generate_title(prompt),
          ai_model: model.presence
        )

        chat.messages.create!(
          type: "UserMessage",
          content: prompt,
          ai_model: chat.ai_model
        )

        chat
      end
    end

    def generate_title(prompt)
      prompt.first(80)
    end
  end

  def needs_assistant_response?
    conversation_messages.ordered.last.role != "assistant"
  end

  def retry_last_message!
    update!(error: nil)

    last_message = conversation_messages.ordered.last

    if last_message.present? && last_message.role == "user"

      ask_assistant_later(last_message)
    end
  end

  def update_latest_response!(provider_response_id)
    update!(latest_assistant_response_id: provider_response_id)
  end

  def add_error(e)
    update! error: e.to_json
    broadcast_append target: "messages", partial: "chats/error", locals: { chat: self }
  end

  def clear_error
    update! error: nil
    broadcast_remove target: "chat-error"
  end

  def assistant
    @assistant ||= Assistant.for_chat(self)
  end

  def ask_assistant_later(message)
    clear_error
    AssistantResponseJob.perform_later(message)
  end

  def ask_assistant(message)
    assistant.respond_to(message)
  end

  def conversation_messages
    visible_messages = messages.visible_in_conversation

    if debug_mode?
      visible_messages
    else
      visible_messages.where(type: [ "UserMessage", "AssistantMessage" ])
    end
  end

  # Revalidates and returns this chat's persisted explicit model selection.
  # There is no family or deployment fallback — a blank selection stays blank
  # so callers must supply an explicit model.
  def effective_ai_model
    return if ai_model.blank?

    Provider::Registry.validate_llm_model!(ai_model)
    ai_model
  end

  private
    def validate_ai_model
      Provider::Registry.validate_llm_model!(ai_model)
    rescue Provider::Registry::Error => e
      errors.add(:ai_model, e.message)
    end
end
