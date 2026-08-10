class Settings::HostingsController < ApplicationController
  layout "settings"

  guard_feature unless: -> { self_hosted? }

  before_action :ensure_admin, only: :clear_cache

  def show
    synth_provider = Provider::Registry.get_provider(:synth)
    @synth_usage = synth_provider&.usage

    load_ai_settings
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

    if hosting_params.key?(:opencode_default_model)
      Setting.opencode_default_model = hosting_params[:opencode_default_model]
    end

    redirect_to settings_hosting_path, notice: t(".success")
  rescue ActiveRecord::RecordInvalid => error
    flash.now[:alert] = t(".failure")
    render :show, status: :unprocessable_entity
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
        :synth_api_key,
        :opencode_default_model
      )
    end

    def ensure_admin
      redirect_to settings_hosting_path, alert: t(".not_authorized") unless Current.user.admin?
    end

    def load_ai_settings
      @ai_connected = false
      @ai_connected_providers = []
      @ai_available_models = []
      @ai_default_model_valid = false

      client = Provider::Opencode::Client.new(
        base_url: Setting.opencode_server_url,
        username: Setting.opencode_server_username,
        password: Setting.opencode_server_password
      )

      provider_data = client.list_providers
      @ai_connected = true
      @ai_connected_providers = provider_data["connected"] || []

      all_providers = provider_data["all"] || []
      @ai_available_models = all_providers
        .select { |p| @ai_connected_providers.include?(p["id"]) }
        .flat_map do |provider|
          (provider["models"] || []).map do |model|
            [ "#{provider['name']} / #{model['name']}", "#{provider['id']}/#{model['id']}" ]
          end
        end

      # Validate and auto-correct default model if needed
      validate_and_correct_default_model
    rescue Faraday::Error, StandardError
      @ai_connected = false
    end

    def validate_and_correct_default_model
      current_model = Setting.opencode_default_model
      return if current_model.blank?

      # Check if current model is in the available models list
      available_model_ids = @ai_available_models.map(&:last)
      @ai_default_model_valid = available_model_ids.include?(current_model)

      # If model is invalid, try to auto-correct to a free model
      unless @ai_default_model_valid
        begin
          free_model = OpencodeModelResolver.resolve
          if free_model.present? && available_model_ids.include?(free_model)
            Setting.opencode_default_model = free_model
            @ai_default_model_valid = true
          end
        rescue OpencodeModelResolver::ResolutionError
          # Could not resolve a free model, leave as is
        end
      end
    end
end
