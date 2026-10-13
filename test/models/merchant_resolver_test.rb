require "test_helper"

class MerchantResolverTest < ActiveSupport::TestCase
  include ProviderTestHelper

  setup do
    @family = families(:dylan_family)
    @merchant = merchants(:netflix)
    @resolver = MerchantResolver.new(@family)
  end

  test "resolves via exact alias match" do
    result = @resolver.resolve("PLVAA PLVAL STORE")
    assert_equal @merchant, result.merchant
    assert_equal :alias_exact, result.method
    assert_equal 1.0, result.confidence
  end

  test "resolves via normalized alias match" do
    result = @resolver.resolve("plvaa plval store")
    assert_equal @merchant, result.merchant
    assert_equal :alias_exact, result.method
  end

  test "returns needs_user_resolution when no alias and no AI" do
    result = @resolver.resolve("UNKNOWN MERCHANT")
    assert_nil result.merchant
    assert_equal :needs_user_resolution, result.method
    assert_equal 0.0, result.confidence
  end

  test "returns no_match for empty input" do
    result = @resolver.resolve("")
    assert_nil result.merchant
    assert_equal :no_match, result.method
  end

  test "returns no_match for nil input" do
    result = @resolver.resolve(nil)
    assert_nil result.merchant
    assert_equal :no_match, result.method
  end

  test "resolves via a confident AI suggestion and passes the saved enrichment model" do
    @family.enrichment_model = "openai/gpt-5-nano"
    llm_provider = mock
    Provider::Registry.stubs(:get_provider).with(:ruby_llm).returns(llm_provider)

    suggestion = Provider::LlmConcept::MerchantSuggestion.new(
      merchant_id: @merchant.id, confidence: 0.92, rationale: "normalized match"
    )

    llm_provider.expects(:suggest_merchant)
      .with(has_entries(model: "openai/gpt-5-nano"))
      .returns(provider_success_response(suggestion))

    result = @resolver.resolve("NETFLIX SUBSCRIPTION")

    assert_equal @merchant, result.merchant
    assert_equal :ai_suggested, result.method
    assert_in_delta 0.92, result.confidence, 0.0001
  end

  test "does not use an AI suggestion below the confidence threshold" do
    @family.enrichment_model = "openai/gpt-5-nano"
    llm_provider = mock
    Provider::Registry.stubs(:get_provider).with(:ruby_llm).returns(llm_provider)

    suggestion = Provider::LlmConcept::MerchantSuggestion.new(
      merchant_id: @merchant.id, confidence: 0.5, rationale: "weak"
    )
    llm_provider.expects(:suggest_merchant).returns(provider_success_response(suggestion))

    result = @resolver.resolve("NETFLIX SUBSCRIPTION")

    assert_nil result.merchant
    assert_equal :needs_user_resolution, result.method
  end

  test "returns needs_user_resolution when the AI suggestion cannot be mapped to a family merchant" do
    @family.enrichment_model = "openai/gpt-5-nano"
    llm_provider = mock
    Provider::Registry.stubs(:get_provider).with(:ruby_llm).returns(llm_provider)

    suggestion = Provider::LlmConcept::MerchantSuggestion.new(
      merchant_id: "does-not-exist", confidence: 0.99, rationale: "invented"
    )
    llm_provider.expects(:suggest_merchant).returns(provider_success_response(suggestion))

    result = @resolver.resolve("NETFLIX SUBSCRIPTION")

    assert_nil result.merchant
    assert_equal :needs_user_resolution, result.method
    assert_equal 0.0, result.confidence
  end

  test "returns needs_user_resolution when the provider fails closed" do
    @family.enrichment_model = "openai/gpt-5-nano"
    llm_provider = mock
    Provider::Registry.stubs(:get_provider).with(:ruby_llm).returns(llm_provider)

    llm_provider.expects(:suggest_merchant)
      .returns(provider_error_response(Provider::RubyLlm::Error.new("model unavailable")))

    result = @resolver.resolve("NETFLIX SUBSCRIPTION")

    assert_nil result.merchant
    assert_equal :needs_user_resolution, result.method
  end
end
