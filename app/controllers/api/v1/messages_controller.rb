# frozen_string_literal: true

class Api::V1::MessagesController < Api::V1::BaseController
  before_action :require_ai_enabled
  before_action :ensure_write_scope, only: [ :create, :retry ]
  before_action :set_chat

  def create
    ai_model = message_params[:model]

    @message = @chat.messages.build(
      content: message_params[:content],
      type: "UserMessage",
      ai_model: ai_model
    )

    # Local input validity before any allowance or catalog work: a blank body
    # can never persist, so it must not consume the allowance or reach the
    # provider. Message's own content validation is reused.
    @message.valid?
    if @message.errors.of_kind?(:content, :blank)
      return render json: { error: "Failed to create message", details: @message.errors.full_messages }, status: :unprocessable_entity
    end

    # Read-only preflight before live catalog work so an exhausted caller never
    # triggers provider validation; the atomic admit below makes the final,
    # race-safe decision.
    return unless preflight_assistant_request!

    # An explicit model is required: there is no deployment default, so a
    # missing reference fails validation and returns the standard
    # provider_configuration_error envelope instead of defaulting silently.
    Provider::Registry.validate_llm_model!(ai_model)

    return unless admit_assistant_request!

    if @message.save
      # UserMessage's after_create_commit callback enqueues the assistant
      # response exactly once; do not enqueue a second job here.
      render :show, status: :created
    else
      render json: { error: "Failed to create message", details: @message.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def retry
    last_message = @chat.messages.ordered.last

    if last_message&.type == "AssistantMessage"
      # Gate the (provider-backed) retry on the allowance before creating the
      # retry placeholder or enqueuing work.
      return unless admit_assistant_request!

      new_message = @chat.messages.create!(
        type: "AssistantMessage",
        content: "",
        ai_model: last_message.ai_model
      )

      AssistantResponseJob.perform_later(new_message)
      render json: { message: "Retry initiated", message_id: new_message.id }, status: :accepted
    else
      render json: { error: "No assistant message to retry" }, status: :unprocessable_entity
    end
  end

  private

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def set_chat
      @chat = Current.user.chats.find(params[:chat_id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: "Chat not found" }, status: :not_found
    end

    def message_params
      params.permit(:content, :model)
    end
end
