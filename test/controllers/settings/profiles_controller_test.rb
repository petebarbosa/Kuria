require "test_helper"

class Settings::ProfilesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:family_admin)
    @member = users(:family_member)
  end

  test "should get show" do
    sign_in @admin
    get settings_profile_path
    assert_response :success
  end

  test "admin can remove a family member" do
    sign_in @admin
    assert_difference("User.count", -1) do
      delete settings_profile_path(user_id: @member)
    end

    assert_redirected_to settings_profile_path
    assert_equal "Member removed successfully.", flash[:notice]
    assert_raises(ActiveRecord::RecordNotFound) { User.find(@member.id) }
  end

  test "admin cannot remove themselves" do
    sign_in @admin
    assert_no_difference("User.count") do
      delete settings_profile_path(user_id: @admin)
    end

    assert_redirected_to settings_profile_path
    assert_equal I18n.t("settings.profiles.destroy.cannot_remove_self"), flash[:alert]
    assert User.find(@admin.id)
  end

  test "non-admin cannot remove members" do
    sign_in @member
    assert_no_difference("User.count") do
      delete settings_profile_path(user_id: @admin)
    end

    assert_redirected_to settings_profile_path
    assert_equal I18n.t("settings.profiles.destroy.not_authorized"), flash[:alert]
    assert User.find(@admin.id)
  end

  test "admin removing a family member also destroys their invitation" do
    # Create an invitation for the member
    invitation = @admin.family.invitations.create!(
      email: @member.email,
      role: "member",
      inviter: @admin
    )

    sign_in @admin

    assert_difference [ "User.count", "Invitation.count" ], -1 do
      delete settings_profile_path(user_id: @member)
    end

    assert_redirected_to settings_profile_path
    assert_equal "Member removed successfully.", flash[:notice]
    assert_raises(ActiveRecord::RecordNotFound) { User.find(@member.id) }
    assert_raises(ActiveRecord::RecordNotFound) { Invitation.find(invitation.id) }
  end

  # --- Family-scoped enrichment model (deployment-mode independent) ---

  OPENAI_MODELS_URL = Provider::RubyLlm::OPENAI_BASE_URL + "/models"
  ENRICHMENT_SUCCESS = "settings.profiles.enrichment_model_success"
  ENRICHMENT_FAILURE = "settings.profiles.enrichment_model_failure"

  # Deterministic live catalog boundary: the authenticated OpenAI `GET /v1/models`
  # request. No live provider API is called.
  def stub_live_openai_models(*model_ids)
    stub_request(:get, OPENAI_MODELS_URL)
      .with(headers: { "Accept" => "application/json", "Authorization" => "Bearer test-openai-key" })
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { object: "list", data: model_ids.map { |id| { "id" => id, "object" => "model" } } }.to_json
      )
  end

  def with_managed_hosting
    Rails.configuration.stubs(:app_mode).returns("managed".inquiry)
    yield
  end

  def enrichment_model_path_params(model)
    { family: { enrichment_model: model } }
  end

  test "admin can select an enrichment model in managed hosting" do
    stub_live_openai_models("gpt-5-nano")
    sign_in @admin

    with_managed_hosting do
      with_env_overrides OPENAI_API_KEY: "test-openai-key", OPENCODE_GO_API_KEY: nil do
        patch enrichment_model_settings_profile_path, params: enrichment_model_path_params("openai/gpt-5-nano")
      end
    end

    assert_redirected_to settings_profile_path
    assert_equal I18n.t(ENRICHMENT_SUCCESS), flash[:notice]
    assert_equal "openai/gpt-5-nano", families(:dylan_family).reload.enrichment_model
  end

  test "admin can select an enrichment model when self hosting" do
    stub_live_openai_models("gpt-5-nano")
    sign_in @admin

    with_self_hosting do
      with_env_overrides OPENAI_API_KEY: "test-openai-key", OPENCODE_GO_API_KEY: nil do
        patch enrichment_model_settings_profile_path, params: enrichment_model_path_params("openai/gpt-5-nano")
      end
    end

    assert_redirected_to settings_profile_path
    assert_equal I18n.t(ENRICHMENT_SUCCESS), flash[:notice]
    assert_equal "openai/gpt-5-nano", families(:dylan_family).reload.enrichment_model
  end

  test "non-admin cannot change the enrichment model in managed hosting" do
    families(:dylan_family).update_column(:enrichment_model, "openai/gpt-5-nano")
    sign_in @member

    with_managed_hosting do
      with_env_overrides OPENAI_API_KEY: "test-openai-key", OPENCODE_GO_API_KEY: nil do
        patch enrichment_model_settings_profile_path, params: enrichment_model_path_params("openai/gpt-4.1")
      end
    end

    assert_redirected_to settings_profile_path
    assert_equal I18n.t("settings.profiles.enrichment_model_not_authorized"), flash[:alert]
    assert_equal "openai/gpt-5-nano", families(:dylan_family).reload.enrichment_model
  end

  test "non-admin cannot change the enrichment model when self hosting" do
    families(:dylan_family).update_column(:enrichment_model, "openai/gpt-5-nano")
    sign_in @member

    with_self_hosting do
      with_env_overrides OPENAI_API_KEY: "test-openai-key", OPENCODE_GO_API_KEY: nil do
        patch enrichment_model_settings_profile_path, params: enrichment_model_path_params("openai/gpt-4.1")
      end
    end

    assert_redirected_to settings_profile_path
    assert_equal I18n.t("settings.profiles.enrichment_model_not_authorized"), flash[:alert]
    assert_equal "openai/gpt-5-nano", families(:dylan_family).reload.enrichment_model
  end

  test "show exposes the enrichment selector and unconfigured state to an admin" do
    stub_live_openai_models("gpt-5-nano", "gpt-4.1")
    sign_in @admin

    with_managed_hosting do
      with_env_overrides OPENAI_API_KEY: "test-openai-key", OPENCODE_GO_API_KEY: nil do
        get settings_profile_path
      end
    end

    assert_response :success
    assert_select "select[name='family[enrichment_model]']" do
      assert_select "option[value='openai/gpt-5-nano']", text: "OpenAI / gpt-5-nano"
      assert_select "option[value='openai/gpt-4.1']", text: "OpenAI / gpt-4.1"
      assert_select "option[value='']", text: "Not configured"
    end
  end

  test "show hides the enrichment selector from a non-admin" do
    stub_live_openai_models("gpt-5-nano")
    sign_in @member

    with_self_hosting do
      with_env_overrides OPENAI_API_KEY: "test-openai-key", OPENCODE_GO_API_KEY: nil do
        get settings_profile_path
      end
    end

    assert_response :success
    assert_select "select[name='family[enrichment_model]']", count: 0
  end

  test "show keeps an unavailable saved enrichment model visible and flagged" do
    families(:dylan_family).update_column(:enrichment_model, "openai/retired-model")
    stub_live_openai_models("gpt-5-nano")
    sign_in @admin

    with_managed_hosting do
      with_env_overrides OPENAI_API_KEY: "test-openai-key", OPENCODE_GO_API_KEY: nil do
        get settings_profile_path
      end
    end

    assert_response :success
    assert_select "select[name='family[enrichment_model]']" do
      assert_select "option[value='openai/retired-model'][selected]",
                    text: "openai/retired-model (no longer available)"
    end
    assert_match I18n.t("settings.profiles.show.enrichment_model_unavailable"), response.body
    # Displaying the page never mutates or replaces the saved reference.
    assert_equal "openai/retired-model", families(:dylan_family).reload.enrichment_model
  end

  test "show flags an unverified enrichment list when the live listing fails" do
    families(:dylan_family).update_column(:enrichment_model, "openai/gpt-5-nano")
    stub_request(:get, OPENAI_MODELS_URL).to_return(status: 500, body: "boom")
    sign_in @admin

    with_managed_hosting do
      with_env_overrides OPENAI_API_KEY: "test-openai-key", OPENCODE_GO_API_KEY: nil do
        get settings_profile_path
      end
    end

    assert_response :success
    assert_match I18n.t("settings.profiles.show.enrichment_model_listing_error"), response.body
  end

  test "admin can clear the enrichment model to unconfigured" do
    families(:dylan_family).update_column(:enrichment_model, "openai/gpt-5-nano")
    sign_in @admin

    with_managed_hosting do
      with_env_overrides OPENAI_API_KEY: nil, OPENCODE_GO_API_KEY: nil do
        patch enrichment_model_settings_profile_path, params: enrichment_model_path_params("")
      end
    end

    assert_redirected_to settings_profile_path
    assert_equal I18n.t(ENRICHMENT_SUCCESS), flash[:notice]
    assert_nil families(:dylan_family).reload.enrichment_model
  end

  test "rejects an unavailable enrichment model without changing the saved value" do
    families(:dylan_family).update_column(:enrichment_model, "openai/gpt-5-nano")
    sign_in @admin

    with_managed_hosting do
      with_env_overrides OPENAI_API_KEY: nil, OPENCODE_GO_API_KEY: nil do
        patch enrichment_model_settings_profile_path, params: enrichment_model_path_params("openai/not-a-model")
      end
    end

    assert_redirected_to settings_profile_path
    assert_equal I18n.t(ENRICHMENT_FAILURE), flash[:alert]
    assert_equal "openai/gpt-5-nano", families(:dylan_family).reload.enrichment_model
  end

  test "a saved model that is no longer live requires reselection on save" do
    families(:dylan_family).update_column(:enrichment_model, "openai/gpt-5-nano")
    stub_live_openai_models("gpt-4.1")
    sign_in @admin

    with_managed_hosting do
      with_env_overrides OPENAI_API_KEY: "test-openai-key", OPENCODE_GO_API_KEY: nil do
        patch enrichment_model_settings_profile_path, params: enrichment_model_path_params("openai/gpt-5-nano")
      end
    end

    assert_redirected_to settings_profile_path
    assert_equal I18n.t(ENRICHMENT_FAILURE), flash[:alert]
    assert_equal "openai/gpt-5-nano", families(:dylan_family).reload.enrichment_model
  end
end
