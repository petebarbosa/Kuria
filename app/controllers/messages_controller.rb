class MessagesController < ApplicationController
  guard_feature unless: -> { Current.user.ai_enabled? }

  before_action :set_chat

  def create
    # Validate the explicit selection before persisting so a missing, invalid,
    # or no-longer-selectable model never creates a message or enqueues an
    # assistant response. UserMessage.create! alone would accept any model on
    # presence and fail later, asynchronously.
    Provider::Registry.validate_llm_model!(message_params[:ai_model])

    @message = UserMessage.create!(
      chat: @chat,
      content: message_params[:content],
      ai_model: message_params[:ai_model]
    )

    redirect_to chat_path(@chat, thinking: true)
  rescue Provider::Registry::Error, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved
    # Nothing was persisted; return to the chat with a clear alert instead of
    # a misleading success.
    redirect_to chat_path(@chat), alert: "Could not send the message. Select an available AI model and try again."
  end

  private
    def set_chat
      @chat = Current.user.chats.find(params[:chat_id])
    end

    def message_params
      params.require(:message).permit(:content, :ai_model)
    end
end
