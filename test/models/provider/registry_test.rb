require "test_helper"

class Provider::RegistryTest < ActiveSupport::TestCase
  OPENAI_MODELS_URL = Provider::RubyLlm::OPENAI_BASE_URL + "/models"
  OPENCODE_GO_MODELS_URL = Provider::RubyLlm::OPENCODE_GO_BASE_URL + "/models"

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

  def model_entry(id, shutdown_date: nil)
    entry = { "id" => id, "object" => "model" }
    entry["shutdown_date"] = shutdown_date if shutdown_date
    entry
  end

  test "synth configured with ENV" do
    Setting.stubs(:synth_api_key).returns(nil)

    with_env_overrides SYNTH_API_KEY: "123" do
      assert_instance_of Provider::Synth, Provider::Registry.get_provider(:synth)
    end
  end

  test "synth configured with Setting" do
    Setting.stubs(:synth_api_key).returns("123")

    with_env_overrides SYNTH_API_KEY: nil do
      assert_instance_of Provider::Synth, Provider::Registry.get_provider(:synth)
    end
  end

  test "synth not configured" do
    Setting.stubs(:synth_api_key).returns(nil)

    with_env_overrides SYNTH_API_KEY: nil do
      assert_nil Provider::Registry.get_provider(:synth)
    end
  end

  test "composite_exchange_rates returns instance" do
    provider = Provider::Registry.get_provider(:composite_exchange_rates)
    assert_instance_of Provider::CompositeExchangeRates, provider
  end

  test "composite_exchange_rates available providers includes composite" do
    registry = Provider::Registry.for_concept(:exchange_rates)
    assert_includes registry.providers.map(&:class), Provider::CompositeExchangeRates
  end

  test "the llm concept routes to RubyLLM regardless of the legacy provider toggle" do
    [ nil, "opencode", "ruby_llm", "banana" ].each do |value|
      with_env_overrides KURIA_LLM_PROVIDER: value do
        provider_classes = Provider::Registry.for_concept(:llm).providers.map(&:class)

        assert_equal [ Provider::RubyLlm ], provider_classes
        assert_instance_of Provider::RubyLlm, Provider::Registry.get_provider(:ruby_llm)
      end
    end
  end

  test "llm_supported_models always exposes the provider catalog" do
    with_env_overrides KURIA_LLM_PROVIDER: nil do
      models = Provider::Registry.llm_supported_models

      assert_equal Provider::RubyLlm::Catalog.manifest, models
      assert models.key?("openai/gpt-5-nano")
      assert models.key?("opencode_go/glm-5.3-flash")
      refute models.key?("opencode_go/grok-4-fast")
    end
  end

  test "llm_default_model is nil so model selection is always explicit" do
    with_env_overrides KURIA_LLM_PROVIDER: "ruby_llm", RUBY_LLM_DEFAULT_MODEL: "openai/gpt-5-nano" do
      assert_nil Provider::Registry.llm_default_model
    end

    with_env_overrides KURIA_LLM_PROVIDER: nil, RUBY_LLM_DEFAULT_MODEL: "openai/gpt-5-nano" do
      assert_nil Provider::Registry.llm_default_model
    end
  end

  test "llm_selectable_models lists live-admitted models for configured accounts only" do
    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano"), model_entry("o3-pro") ], auth_key: "test-openai-key")

    with_env_overrides OPENAI_API_KEY: "test-openai-key", OPENCODE_GO_API_KEY: nil do
      options = Provider::Registry.llm_selectable_models

      assert_includes options, [ "OpenAI / gpt-5-nano", "openai/gpt-5-nano" ]
      refute(options.any? { |_label, reference| reference.start_with?("opencode_go/") })
      refute(options.any? { |_label, reference| reference == "openai/o3-pro" })
    end
  end

  test "llm_selectable_models fails closed with a Registry::Error when a configured live list cannot be read" do
    stub_request(:get, OPENAI_MODELS_URL)
      .with(headers: { "Accept" => "application/json", "Authorization" => "Bearer test-openai-key" })
      .to_return(status: 500, body: "boom")

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      error = assert_raises(Provider::Registry::Error) { Provider::Registry.llm_selectable_models }
      assert_match(/Live AI model selection is unavailable/, error.message)
    end
  end

  test "valid_llm_model? validates an explicit reference against configured live model membership" do
    stub_live_models(:openai, entries: [ model_entry("gpt-5-nano"), model_entry("gpt-4o") ], auth_key: "test-openai-key")

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      assert Provider::Registry.valid_llm_model?("openai/gpt-5-nano")
      assert Provider::Registry.valid_llm_model?("openai/gpt-4o")
    end
  end

  test "valid_llm_model? rejects a catalogued model missing from the configured live list" do
    stub_live_models(:openai, entries: [ model_entry("gpt-4o") ], auth_key: "test-openai-key")

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      refute Provider::Registry.valid_llm_model?("openai/gpt-5-nano")

      error = assert_raises(Provider::Registry::Error) do
        Provider::Registry.validate_llm_model!("openai/gpt-5-nano")
      end
      assert_match(/openai\/gpt-5-nano/, error.message)
    end
  end

  test "valid_llm_model? rejects stale, uncatalogued, and non-RubyLLM references without a live request" do
    Provider::RubyLlm::Catalog.any_instance.expects(:available?).never

    with_env_overrides OPENAI_API_KEY: "test-openai-key", OPENCODE_GO_API_KEY: "test-go-key" do
      refute Provider::Registry.valid_llm_model?("opencode/minimax-m2.5-free")
      refute Provider::Registry.valid_llm_model?("openai/does-not-exist")
      refute Provider::Registry.valid_llm_model?("anthropic/claude-3-5-sonnet")
      refute Provider::Registry.valid_llm_model?("gpt-5-nano")
      refute Provider::Registry.valid_llm_model?("")
      refute Provider::Registry.valid_llm_model?(nil)
    end

    # A reference that was catalogued in a previous phase is stale now.
    with_env_overrides OPENCODE_GO_API_KEY: "test-go-key" do
      refute Provider::Registry.valid_llm_model?("opencode_go/grok-4-fast")

      error = assert_raises(Provider::Registry::Error) do
        Provider::Registry.validate_llm_model!("opencode_go/grok-4-fast")
      end
      assert_match(/opencode_go\/grok-4-fast/, error.message)
    end
  end

  test "valid_llm_model? rejects catalogued references whose account credential is not configured" do
    Provider::RubyLlm::Catalog.any_instance.expects(:available?).never

    with_env_overrides OPENAI_API_KEY: nil, OPENCODE_GO_API_KEY: nil do
      refute Provider::Registry.valid_llm_model?("openai/gpt-5-nano")
      refute Provider::Registry.valid_llm_model?("opencode_go/glm-5.3-flash")
    end
  end

  test "validate_llm_model! fails closed with a Registry::Error when the configured live list cannot be read" do
    stub_request(:get, OPENAI_MODELS_URL)
      .with(headers: { "Accept" => "application/json", "Authorization" => "Bearer test-openai-key" })
      .to_return(status: 500, body: "boom")

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      assert_raises(Provider::RubyLlm::Error) { Provider::Registry.valid_llm_model?("openai/gpt-5-nano") }

      error = assert_raises(Provider::Registry::Error) do
        Provider::Registry.validate_llm_model!("openai/gpt-5-nano")
      end
      assert_match(/Live AI model validation is unavailable/, error.message)
      assert_match(/openai\/gpt-5-nano/, error.message)
    end
  end
end
