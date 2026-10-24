require "test_helper"

# Cost estimates are derived only from the OpenAI section of RubyLLM's bundled
# registry. OpenCode Go is a separate billing account even though it reuses the
# OpenAI protocol, so its prices stay explicitly unknown rather than borrowing
# a same-named model's rate from another registry provider.
class Provider::RubyLlm::PricingTest < ActiveSupport::TestCase
  # gpt-5-nano in the RubyLLM 2.1.1 bundled registry:
  # input $0.05/M, output $0.40/M, cache read $0.005/M.
  OPENAI_TOKEN_USAGE = {
    input_tokens: 60,
    output_tokens: 20,
    cache_read_tokens: 40,
    cache_write_tokens: nil,
    reasoning_tokens: nil
  }.freeze

  test "prices a reported OpenAI request from the explicit bundled registry" do
    result = Provider::RubyLlm::Pricing.estimate(
      account: :openai,
      model_id: "gpt-5-nano",
      tokens: OPENAI_TOKEN_USAGE
    )

    assert result.known
    assert_equal Provider::RubyLlm::Pricing::SOURCE, result.source
    assert_nil result.reason
    assert_in_delta 0.0000112, result.usd, 1e-12
  end

  test "prices cache reads separately from standard input" do
    result = Provider::RubyLlm::Pricing.estimate(
      account: :openai,
      model_id: "gpt-5-nano",
      tokens: { input_tokens: 0, output_tokens: 0, cache_read_tokens: 1_000_000 }
    )

    assert result.known
    assert_in_delta 0.005, result.usd, 1e-12
  end

  test "a reported zero-token request is a known zero, not unknown" do
    result = Provider::RubyLlm::Pricing.estimate(
      account: :openai,
      model_id: "gpt-5-nano",
      tokens: { input_tokens: 0, output_tokens: 0, cache_read_tokens: 0 }
    )

    assert result.known
    assert_equal 0.0, result.usd
  end

  test "OpenCode Go pricing is explicitly unknown rather than borrowed from another registry provider" do
    result = Provider::RubyLlm::Pricing.estimate(
      account: :opencode_go,
      model_id: "deepseek-v4-flash",
      tokens: { input_tokens: 1_000, output_tokens: 1_000, cache_read_tokens: 0 }
    )

    refute result.known
    assert_nil result.usd
    assert_nil result.source
    assert_equal "no_authoritative_pricing_source", result.reason
  end

  test "an OpenAI model missing from the registry is unknown, not zero" do
    result = Provider::RubyLlm::Pricing.estimate(
      account: :openai,
      model_id: "not-a-registry-model",
      tokens: { input_tokens: 10, output_tokens: 10 }
    )

    refute result.known
    assert_nil result.usd
    assert_equal Provider::RubyLlm::Pricing::SOURCE, result.source
    assert_equal "model_not_in_registry", result.reason
  end

  test "missing usage is unknown rather than a fabricated zero" do
    result = Provider::RubyLlm::Pricing.estimate(
      account: :openai,
      model_id: "gpt-5-nano",
      tokens: { input_tokens: nil, output_tokens: nil }
    )

    refute result.known
    assert_nil result.usd
    assert_equal "usage_unavailable", result.reason
  end

  test "partially reported usage is unknown rather than under-priced" do
    result = Provider::RubyLlm::Pricing.estimate(
      account: :openai,
      model_id: "gpt-5-nano",
      tokens: { input_tokens: 10, output_tokens: nil }
    )

    refute result.known
    assert_nil result.usd
    assert_equal "usage_incomplete", result.reason
  end

  test "reasoning tokens are not priced twice when the registry folds them into output" do
    without_reasoning = Provider::RubyLlm::Pricing.estimate(
      account: :openai,
      model_id: "gpt-5-nano",
      tokens: { input_tokens: 100, output_tokens: 50 }
    )
    with_reasoning = Provider::RubyLlm::Pricing.estimate(
      account: :openai,
      model_id: "gpt-5-nano",
      tokens: { input_tokens: 100, output_tokens: 50, reasoning_tokens: 25 }
    )

    assert without_reasoning.known
    assert with_reasoning.known
    assert_in_delta without_reasoning.usd, with_reasoning.usd, 1e-12
  end

  test "aggregate sums every known entry and stays unknown if any entry is unknown" do
    known = Provider::RubyLlm::Pricing.estimate(
      account: :openai,
      model_id: "gpt-5-nano",
      tokens: { input_tokens: 10, output_tokens: 5 }
    )
    other_known = Provider::RubyLlm::Pricing.estimate(
      account: :openai,
      model_id: "gpt-5-nano",
      tokens: { input_tokens: 20, output_tokens: 10 }
    )
    unknown = Provider::RubyLlm::Pricing.estimate(
      account: :openai,
      model_id: "gpt-5-nano",
      tokens: { input_tokens: nil, output_tokens: nil }
    )

    summed = Provider::RubyLlm::Pricing.aggregate([ known, other_known ])
    assert summed.known
    assert_in_delta known.usd + other_known.usd, summed.usd, 1e-12

    incomplete = Provider::RubyLlm::Pricing.aggregate([ known, unknown ])
    refute incomplete.known
    assert_nil incomplete.usd
    assert_equal "usage_unavailable", incomplete.reason
  end

  test "a positive bucket without a published rate is unknown rather than free" do
    result = Provider::RubyLlm::Pricing.estimate(
      account: :openai,
      model_id: "gpt-5-nano",
      tokens: { input_tokens: 10, output_tokens: 10, cache_write_tokens: 10 }
    )

    refute result.known
    assert_nil result.usd
    assert_equal "missing_rate", result.reason
  end
end
