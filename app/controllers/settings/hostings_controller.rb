class Settings::HostingsController < ApplicationController
  layout "settings"

  guard_feature unless: -> { self_hosted? }

  before_action :ensure_admin, only: :clear_cache

  def show
    load_show_data
  end

  def update
    if hosting_params.key?(:require_invite_for_signup)
      Setting.require_invite_for_signup = hosting_params[:require_invite_for_signup]
    end

    if hosting_params.key?(:require_email_confirmation)
      Setting.require_email_confirmation = hosting_params[:require_email_confirmation]
    end

    if hosting_params.key?(:synth_api_key)
      Setting.synth_api_key = hosting_params[:synth_api_key]
    end

    redirect_to settings_hosting_path, notice: t(".success")
  rescue ActiveRecord::RecordInvalid => error
    render_update_failure
  end

  def clear_cache
    DataCacheClearJob.perform_later(Current.family)
    redirect_to settings_hosting_path, notice: t(".cache_cleared")
  end

  private
    def hosting_params
      params.require(:setting).permit(
        :require_invite_for_signup,
        :require_email_confirmation,
        :synth_api_key
      )
    end

    def ensure_admin
      redirect_to settings_hosting_path, alert: t(".not_authorized") unless Current.user.admin?
    end

    def load_show_data
      synth_provider = Provider::Registry.get_provider(:synth)
      @synth_usage = synth_provider&.usage

      load_ai_settings
    end

    def render_update_failure
      flash.now[:alert] = t(".failure")
      load_show_data
      render :show, status: :unprocessable_entity
    end

    def load_ai_settings
      @ai_ruby_llm_mode = true
      @ai_connected = false
      @ai_connected_providers = []
      @ai_available_models = []

      load_ruby_llm_ai_settings
    end

    def load_ruby_llm_ai_settings
      # Availability reflects the RubyLLM account credentials resolved for the
      # deployment (environment first, then encrypted credentials). There is no
      # deployment default model: the user picks a live model per chat, so the
      # hosting page only reports configured accounts.
      configured = Provider::RubyLlm.supported_models.select do |_reference, metadata|
        Provider::RubyLlm::Catalog.api_key_for(metadata[:credential_source]).present?
      end

      @ai_connected_providers = configured.values
        .map { |metadata| metadata[:credential_source] }
        .uniq
        .map { |source| ruby_llm_account_label(source) }

      @ai_connected = @ai_connected_providers.any?

      # Live selectable models (manifest ∩ live /v1/models). A listing failure
      # must not blank the hosting page, so it degrades to no models.
      @ai_available_models = begin
        Provider::Registry.llm_selectable_models
      rescue Provider::Registry::Error
        []
      end
    end

    def ruby_llm_account_label(credential_source)
      case credential_source
      when "OPENAI_API_KEY" then "OpenAI"
      when "OPENCODE_GO_API_KEY" then "OpenCode Go"
      else credential_source
      end
    end
end
