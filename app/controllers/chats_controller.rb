class ChatsController < ApplicationController
  include ActionView::RecordIdentifier

  before_action :set_chat, only: [ :show, :edit, :update, :destroy ]
  before_action :load_ai_model_options, only: [ :index, :new, :show ]

  def index
    @chat = nil # override application_controller default behavior of setting @chat to last viewed chat
    @chats = Current.user.chats.order(created_at: :desc)
  end

  def show
    set_last_viewed_chat(@chat)
  end

  def new
    @chat = Current.user.chats.new(title: new_chat_title)
  end

  def create
    begin
      @chat = Current.user.chats.start!(chat_params[:content], model: chat_params[:ai_model])
    rescue Provider::Registry::Error, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved
      # start! is transactional, so a rejected model (missing, invalid, or no
      # longer selectable) persists neither the chat nor its first message.
      # Re-render the form with a clear alert instead of reporting success.
      @chat = Current.user.chats.new(title: new_chat_title)
      load_ai_model_options
      flash.now[:alert] = "Could not start the chat. Check the message and select an available AI model, then try again."
      render :new, status: :unprocessable_entity
    else
      set_last_viewed_chat(@chat)
      redirect_to chat_path(@chat, thinking: true)
    end
  end

  def edit
  end

  def update
    @chat.update!(chat_params)

    respond_to do |format|
      format.html { redirect_back_or_to chat_path(@chat), notice: "Chat updated" }
      format.turbo_stream { render turbo_stream: turbo_stream.replace(dom_id(@chat, :title), partial: "chats/chat_title", locals: { chat: @chat }) }
    end
  end

  def destroy
    @chat.destroy
    clear_last_viewed_chat

    redirect_to chats_path, notice: "Chat was successfully deleted"
  end

  def retry
    @chat.retry_last_message!
    redirect_to chat_path(@chat, thinking: true)
  end

  private
    def set_chat
      @chat = Current.user.chats.find(params[:id])
    end

    # Populates the model picker for every render of the chat form. RubyLLM is
    # the active LLM provider when the :llm concept resolves to it; only then
    # are the live selectable options offered. A failed live listing is reduced
    # to a generic error flag: the view shows a credential-agnostic message and
    # the registry error (which may name an env credential) is never surfaced.
    def load_ai_model_options
      @ai_ruby_llm_mode = Provider::Registry.for_concept(:llm).providers.any? { |provider| provider.is_a?(Provider::RubyLlm) }
      @ai_selectable_models = @ai_ruby_llm_mode ? Provider::Registry.llm_selectable_models : []
      @ai_selectable_models_error = nil
    rescue Provider::Registry::Error
      @ai_selectable_models = []
      @ai_selectable_models_error = true
    end

    def new_chat_title
      "New chat #{Time.current.strftime("%Y-%m-%d %H:%M")}"
    end

    def set_last_viewed_chat(chat)
      Current.user.update!(last_viewed_chat: chat)
    end

    def clear_last_viewed_chat
      Current.user.update!(last_viewed_chat: nil)
    end

    def chat_params
      params.require(:chat).permit(:title, :content, :ai_model)
    end
end
