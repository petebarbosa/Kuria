require "test_helper"
require "ostruct"

class Settings::HostingsControllerTest < ActionDispatch::IntegrationTest
  include ProviderTestHelper

  OPENAI_MODELS_URL = Provider::RubyLlm::OPENAI_BASE_URL + "/models"
  OPENCODE_GO_MODELS_URL = Provider::RubyLlm::OPENCODE_GO_BASE_URL + "/models"

  setup do
    sign_in users(:family_admin)

    @provider = mock
    Provider::Registry.stubs(:get_provider).with(:synth).returns(@provider)
    # The settings layout resolves AI availability through User#ai_available?,
    # which asks the registry for the RubyLLM provider.
    Provider::Registry.stubs(:get_provider).with(:ruby_llm).returns(Provider::RubyLlm.new)

    @usage_response = provider_success_response(
      OpenStruct.new(
        used: 10,
        limit: 100,
        utilization: 10,
        plan: "free",
      )
    )
  end

  teardown do
    # DB writes are rolled back by the test transaction; clear any cached
    # Settings so no state leaks across tests.
    Setting.clear_cache
  end

  # Deterministic live catalog boundary: stub the authenticated `GET /v1/models`
  # request. Header expectations double as assertions that the correct account
  # credential is sent.
  def stub_live_models(account, entries:, auth_key:)
    url = account == :openai ? OPENAI_MODELS_URL : OPENCODE_GO_MODELS_URL

    stub_request(:get, url)
      .with(headers: { "Accept" => "application/json", "Authorization" => "Bearer #{auth_key}" })
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { object: "list", data: entries }.to_json
      )
  end

  def model_entry(id)
    { "id" => id, "object" => "model" }
  end

  test "cannot edit when self hosting is disabled" do
    Rails.configuration.stubs(:app_mode).returns("managed".inquiry)

    get settings_hosting_url
    assert_response :forbidden

    patch settings_hosting_url, params: { setting: { require_invite_for_signup: true } }
    assert_response :forbidden
  end

  test "should get edit when self hosting is enabled" do
    @provider.expects(:usage).returns(@usage_response)

    with_self_hosting do
      with_env_overrides OPENAI_API_KEY: nil, OPENCODE_GO_API_KEY: nil do
        get settings_hosting_url
        assert_response :success
      end
    end
  end

  test "can update settings when self hosting is enabled" do
    with_self_hosting do
      patch settings_hosting_url, params: { setting: { synth_api_key: "1234567890" } }

      assert_equal "1234567890", Setting.synth_api_key
    end
  end

  test "can clear data cache when self hosting is enabled" do
    account = accounts(:investment)
    holding = account.holdings.first
    exchange_rate = exchange_rates(:one)
    security_price = holding.security.prices.first
    account_balance = account.balances.create!(date: Date.current, balance: 1000, currency: "USD")

    with_self_hosting do
      perform_enqueued_jobs(only: DataCacheClearJob) do
        delete clear_cache_settings_hosting_url
      end
    end

    assert_redirected_to settings_hosting_url
    assert_equal I18n.t("settings.hostings.clear_cache.cache_cleared"), flash[:notice]

    assert_not ExchangeRate.exists?(exchange_rate.id)
    assert_not Security::Price.exists?(security_price.id)
    assert_not Holding.exists?(holding.id)
    assert_not Balance.exists?(account_balance.id)
  end

  test "can clear data only when admin" do
    with_self_hosting do
      sign_in users(:family_member)

      assert_no_enqueued_jobs do
        delete clear_cache_settings_hosting_url
      end

      assert_redirected_to settings_hosting_url
      assert_equal I18n.t("settings.hostings.not_authorized"), flash[:alert]
    end
  end

  test "hosting always uses RubyLLM mode regardless of the legacy provider toggle" do
    @provider.expects(:usage).times(3).returns(@usage_response)
    Provider::Opencode::Client.expects(:new).never
    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")

    with_self_hosting do
      [ nil, "opencode", "ruby_llm" ].each do |value|
        with_env_overrides KURIA_LLM_PROVIDER: value, OPENAI_API_KEY: "test-openai-key", OPENCODE_GO_API_KEY: nil do
          get settings_hosting_url

          assert_response :success
          assert controller.instance_variable_get(:@ai_ruby_llm_mode)
        end
      end
    end
  end

  test "RubyLLM show never constructs an OpenCode client" do
    @provider.expects(:usage).returns(@usage_response)
    Provider::Opencode::Client.expects(:new).never
    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano") ], auth_key: "test-openai-key")

    with_self_hosting do
      with_env_overrides OPENAI_API_KEY: "test-openai-key", OPENCODE_GO_API_KEY: nil do
        get settings_hosting_url
      end
    end

    assert_response :success
  end

  test "RubyLLM show populates AI settings from the live selectable models" do
    @provider.expects(:usage).returns(@usage_response)
    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano"), model_entry("o3-pro") ], auth_key: "test-openai-key")

    with_self_hosting do
      with_env_overrides OPENAI_API_KEY: "test-openai-key", OPENCODE_GO_API_KEY: nil do
        get settings_hosting_url
      end
    end

    assert_response :success
    assert controller.instance_variable_get(:@ai_ruby_llm_mode)
    assert controller.instance_variable_get(:@ai_connected)
    assert_equal [ "OpenAI" ], controller.instance_variable_get(:@ai_connected_providers)
    assert_equal [ [ "OpenAI / gpt-5-nano", "openai/gpt-5-nano" ] ], controller.instance_variable_get(:@ai_available_models)
    # No deployment default model is exposed or validated in RubyLLM mode.
    assert_nil controller.instance_variable_get(:@ai_default_model_valid)
  end

  test "RubyLLM show is disconnected and offers no models when no catalog credential is configured" do
    @provider.expects(:usage).returns(@usage_response)

    with_self_hosting do
      with_env_overrides OPENAI_API_KEY: nil, OPENCODE_GO_API_KEY: nil do
        get settings_hosting_url
      end
    end

    assert_response :success
    refute controller.instance_variable_get(:@ai_connected)
    assert_empty controller.instance_variable_get(:@ai_connected_providers)
    assert_empty controller.instance_variable_get(:@ai_available_models)
  end

  test "RubyLLM show stays usable when the live model listing fails" do
    @provider.expects(:usage).returns(@usage_response)
    stub_request(:get, OPENAI_MODELS_URL)
      .with(headers: { "Accept" => "application/json", "Authorization" => "Bearer test-openai-key" })
      .to_return(status: 500, body: "boom")

    with_self_hosting do
      with_env_overrides OPENAI_API_KEY: "test-openai-key", OPENCODE_GO_API_KEY: nil do
        get settings_hosting_url
      end
    end

    assert_response :success
    assert controller.instance_variable_get(:@ai_connected)
    assert_empty controller.instance_variable_get(:@ai_available_models)
  end

  test "does not accept a runtime RubyLLM default model in hosting settings" do
    with_self_hosting do
      patch settings_hosting_url, params: { setting: { ruby_llm_default_model: "openai/gpt-4o" } }

      assert_redirected_to settings_hosting_url
      refute Setting.respond_to?(:ruby_llm_default_model)
    end
  end

  test "does not persist a deployment default model through hosting settings" do
    original = Setting.opencode_default_model

    with_self_hosting do
      patch settings_hosting_url, params: { setting: { opencode_default_model: "opencode/other-model" } }

      assert_redirected_to settings_hosting_url

      # The value is unchanged: nil when no default is stored, otherwise the
      # previously stored value.
      if original.nil?
        assert_nil Setting.opencode_default_model
      else
        assert_equal original, Setting.opencode_default_model
      end
    end
  end

  test "does not accept OpenAI or OpenCode Go API keys in hosting settings" do
    with_self_hosting do
      patch settings_hosting_url, params: { setting: { openai_api_key: "sk-test-123", opencode_go_api_key: "go-test-456" } }

      assert_redirected_to settings_hosting_url
      refute Setting.respond_to?(:openai_api_key)
      refute Setting.respond_to?(:opencode_go_api_key)
    end
  end
end
