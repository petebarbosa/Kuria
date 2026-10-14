class Settings::ProfilesController < ApplicationController
  layout "settings"

  before_action :ensure_admin, only: :enrichment_model

  def show
    @user = Current.user
    @users = Current.family.users.order(:created_at)
    @pending_invitations = Current.family.invitations.pending
    load_enrichment_model_settings
  end

  # Persists the family's explicit enrichment model choice. Available in every
  # deployment mode (this page is not self-hosting-specific) and restricted to
  # family administrators. The reference is revalidated against the live
  # catalog on every save, so an unavailable model is rejected and the admin
  # must reselect; the saved value is never replaced silently and a no-op save
  # reports an error rather than success.
  def enrichment_model
    model = requested_enrichment_model
    Provider::Registry.validate_llm_model!(model) if model

    Current.family.update!(enrichment_model: model)
    redirect_to settings_profile_path, notice: t(".enrichment_model_success")
  rescue Provider::Registry::Error, ActiveRecord::RecordInvalid
    redirect_to settings_profile_path, alert: t(".enrichment_model_failure")
  end

  def destroy
    unless Current.user.admin?
      flash[:alert] = t("settings.profiles.destroy.not_authorized")
      redirect_to settings_profile_path
      return
    end

    @user = Current.family.users.find(params[:user_id])

    if @user == Current.user
      flash[:alert] = t("settings.profiles.destroy.cannot_remove_self")
      redirect_to settings_profile_path
      return
    end

    if @user.destroy
      # Also destroy the invitation associated with this user for this family
      Current.family.invitations.find_by(email: @user.email)&.destroy
      flash[:notice] = "Member removed successfully."
    else
      flash[:alert] = "Failed to remove member."
    end

    redirect_to settings_profile_path
  end

  private
    def ensure_admin
      redirect_to settings_profile_path, alert: t(".enrichment_model_not_authorized") unless Current.user.admin?
    end

    # The request must name the field. An omitted family or enrichment_model
    # key, or a malformed (non-string) value, is rejected through the same
    # failure shape as an invalid model rather than being read as a clear, so
    # the saved choice can never be dropped by omission. An explicitly supplied
    # empty string remains a legitimate clear to unconfigured.
    def requested_enrichment_model
      family_params = params[:family]
      value = family_params[:enrichment_model] if family_params.respond_to?(:key?) && family_params.key?(:enrichment_model)

      raise ActiveRecord::RecordInvalid.new(Current.family) unless value.is_a?(String)

      value.presence
    end

    # Family-scoped enrichment model selection. The saved reference is shown
    # as-is: when it is not among the currently selectable models it is added
    # to the options as unavailable, never dropped or swapped for another
    # model. A blank reference is the unconfigured state, and there is no
    # default or first-registered model.
    def load_enrichment_model_settings
      @ai_available_models = begin
        Provider::Registry.llm_selectable_models
      rescue Provider::Registry::Error
        @ai_available_models_error = true
        []
      end

      @enrichment_model = Current.family.enrichment_model
      selectable = @ai_available_models.map { |_label, reference| reference }

      @enrichment_model_stale = !@ai_available_models_error &&
        @enrichment_model.present? &&
        !selectable.include?(@enrichment_model)

      @enrichment_model_choices = @ai_available_models.dup
      @enrichment_model_choices << [ enrichment_model_option_label, @enrichment_model ] if @enrichment_model.present? && !selectable.include?(@enrichment_model)
    end

    # A saved model left out of a verified list is labelled stale; when the
    # list itself failed to load the raw reference is shown unannotated, since
    # its availability was not actually checked.
    def enrichment_model_option_label
      return @enrichment_model if @ai_available_models_error

      t(".enrichment_model_unavailable_option", model: @enrichment_model)
    end
end
