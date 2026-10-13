require "test_helper"

class FamilyTest < ActiveSupport::TestCase
  include SyncableInterfaceTest

  OPENAI_MODELS_URL = Provider::RubyLlm::OPENAI_BASE_URL + "/models"

  def setup
    @syncable = families(:dylan_family)
  end

  # Deterministic live catalog boundary: the authenticated OpenAI `GET /v1/models`
  # request. No live provider API is ever called.
  def stub_openai_models(*model_ids)
    stub_request(:get, OPENAI_MODELS_URL)
      .with(headers: { "Accept" => "application/json", "Authorization" => "Bearer test-openai-key" })
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { object: "list", data: model_ids.map { |id| { "id" => id, "object" => "model" } } }.to_json
      )
  end

  test "enrichment model is unconfigured by default" do
    assert_nil @syncable.enrichment_model
  end

  test "stores an explicitly selected, currently available enrichment model" do
    stub_openai_models("gpt-5-nano")

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      @syncable.update!(enrichment_model: "openai/gpt-5-nano")
    end

    assert_equal "openai/gpt-5-nano", @syncable.reload.enrichment_model
  end

  test "normalizes a blank enrichment model to unconfigured" do
    @syncable.update_column(:enrichment_model, "openai/gpt-5-nano")

    @syncable.update!(enrichment_model: "")

    assert_nil @syncable.reload.enrichment_model
  end

  test "rejects an uncatalogued enrichment model and never replaces it" do
    @syncable.update_column(:enrichment_model, "openai/gpt-5-nano")

    assert_not @syncable.update(enrichment_model: "openai/not-a-real-model")

    assert @syncable.errors[:enrichment_model].present?
    assert_equal "openai/gpt-5-nano", @syncable.reload.enrichment_model
  end

  test "rejects a catalogued enrichment model that is no longer live" do
    @syncable.update_column(:enrichment_model, "openai/gpt-5-nano")
    stub_openai_models("gpt-4.1")

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      assert_not @syncable.update(enrichment_model: "openai/gpt-5.4")
    end

    assert @syncable.errors[:enrichment_model].present?
    assert_equal "openai/gpt-5-nano", @syncable.reload.enrichment_model
  end

  test "fails closed when the live model list cannot be loaded" do
    stub_request(:get, OPENAI_MODELS_URL).to_return(status: 500, body: "boom")

    with_env_overrides OPENAI_API_KEY: "test-openai-key" do
      assert_not @syncable.update(enrichment_model: "openai/gpt-5-nano")
    end

    assert @syncable.errors[:enrichment_model].present?
    assert_nil @syncable.reload.enrichment_model
  end
end
