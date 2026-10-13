class MessagesController < ApplicationController
  include AssistantRequestLimitable

  guard_feature unless: -> { Current.user.ai_enabled? }

  before_action :set_chat

  def create
    @message = @chat.messages.build(
      content: message_params[:content],
      type: "UserMessage",
      ai_model: message_params[:ai_model]
    )

    # Local input validity before any allowance or catalog work: a blank body
    # can never persist, so it must not consume the allowance or reach the
    # provider. Message's own content validation is reused.
    @message.valid?
    if @message.errors.of_kind?(:content, :blank)
      return redirect_to chat_path(@chat), alert: message_error_alert
    end

    # Read-only preflight before live catalog work so an exhausted caller never
    # triggers provider validation; the atomic admit below makes the final,
    # race-safe decision.
    return unless preflight_assistant_request!

    # Validate the explicit selection before persisting so a missing, invalid,
    # or no-longer-selectable model never creates a message or enqueues an
    # assistant response.
    Provider::Registry.validate_llm_model!(message_params[:ai_model])

    return unless admit_assistant_request!

    @message.save!
    redirect_to chat_path(@chat, thinking: true)
  rescue Provider::Registry::Error, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved
    # Nothing was persisted; return to the chat with a clear alert instead of
    # a misleading success.
    redirect_to chat_path(@chat), alert: message_error_alert
  end

  private
    def set_chat
      @chat = Current.user.chats.find(params[:chat_id])
    end

    def message_error_alert
      "Could not send the message. Select an available AI model and try again."
    end

    def message_params
      params.require(:message).permit(:content, :ai_model)
    end
end
