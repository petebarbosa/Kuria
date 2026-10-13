# frozen_string_literal: true

class Api::V1::ChatsController < Api::V1::BaseController
  include Pagy::Method
  before_action :require_ai_enabled
  before_action :ensure_read_scope, only: [ :index, :show ]
  before_action :ensure_write_scope, only: [ :create, :update, :destroy ]
  before_action :set_chat, only: [ :show, :update, :destroy ]

  def index
    @pagy, @chats = pagy(Current.user.chats.ordered, items: 20)
  end

  def show
    return unless @chat
    @pagy, @messages = pagy(@chat.messages.ordered, items: 50)
  end

  def create
    @chat = Current.user.chats.build(title: chat_params[:title])

    # Require an explicit model before persisting anything so a missing or
    # invalid reference leaves neither a Chat nor a Message and returns the
    # standard provider_configuration_error envelope. There is no deployment
    # default to fall back to.
    if chat_params[:message].present?
      ai_model = chat_params[:model]
      Provider::Registry.validate_llm_model!(ai_model)
    end

    # Count the request against the authenticated user's allowance before any
    # storage mutation. A rejection returns 429/503 without creating a Chat or
    # Message and without queuing provider work.
    return unless admit_assistant_request!

    if @chat.save
      if chat_params[:message].present?
        @message = @chat.messages.build(
          content: chat_params[:message],
          type: "UserMessage",
          ai_model: ai_model
        )

        if @message.save
          # UserMessage's after_create_commit callback enqueues the assistant
          # response exactly once; do not enqueue a second job here.
          render :show, status: :created
        else
          @chat.destroy
          render json: { error: "Failed to create initial message", details: @message.errors.full_messages }, status: :unprocessable_entity
        end
      else
        render :show, status: :created
      end
    else
      render json: { error: "Failed to create chat", details: @chat.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def update
    return unless @chat

    if @chat.update(update_chat_params)
      render :show
    else
      render json: { error: "Failed to update chat", details: @chat.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    return unless @chat
    @chat.destroy
    head :no_content
  end

  private

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def set_chat
      @chat = Current.user.chats.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: "Chat not found" }, status: :not_found
    end

    def chat_params
      params.permit(:title, :message, :model)
    end

    def update_chat_params
      params.permit(:title)
    end
end
