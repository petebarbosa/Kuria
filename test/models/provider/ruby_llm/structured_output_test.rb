require "test_helper"

# Extraction boundary for RubyLLM 2.1 structured output. The public
# `Message#parsed` accessor is authoritative for JSON String content; messages
# that already carry a Hash (existing fake seams) must keep working, and
# malformed JSON/nil refusals must still fail closed with a safe message.
class Provider::RubyLlm::StructuredOutputTest < ActiveSupport::TestCase
  HashMessage = Struct.new(:content)

  test "reads RubyLLM 2.1 JSON String content through the public parsed accessor" do
    json = {
      "categorizations" => [
        { "transaction_id" => "1", "category_name" => "Groceries" }
      ]
    }.to_json
    message = RubyLLM::Message.new(role: :assistant, content: json)

    content = Provider::RubyLlm::StructuredOutput.content_hash!(message, "auto-categorize")

    assert_equal({ "categorizations" => [ { "transaction_id" => "1", "category_name" => "Groceries" } ] }, content)
    assert_kind_of String, message.content
    assert_equal json, message.content
  end

  test "keeps accepting messages that already carry a Hash" do
    content = { "categorizations" => [] }
    message = HashMessage.new(content)

    assert_same content, Provider::RubyLlm::StructuredOutput.content_hash!(message, "auto-categorize")
  end

  test "fails closed on malformed JSON without leaking the raw content" do
    message = RubyLLM::Message.new(role: :assistant, content: "SECRET-NOT-JSON")

    error = assert_raises(Provider::RubyLlm::Error) do
      Provider::RubyLlm::StructuredOutput.content_hash!(message, "auto-categorize")
    end

    assert_match(/did not return structured JSON \(got a String\); failing closed/, error.message)
    refute_match(/SECRET-NOT-JSON/, error.message)
  end

  test "fails closed on a nil response or provider refusal" do
    message = RubyLLM::Message.new(role: :assistant, content: nil)

    error = assert_raises(Provider::RubyLlm::Error) do
      Provider::RubyLlm::StructuredOutput.content_hash!(message, "suggest-merchant")
    end

    assert_match(/did not return structured JSON \(got an empty response or provider refusal\); failing closed/, error.message)
  end

  test "fails closed on JSON that is not an object" do
    message = RubyLLM::Message.new(role: :assistant, content: "[1,2,3]")

    error = assert_raises(Provider::RubyLlm::Error) do
      Provider::RubyLlm::StructuredOutput.content_hash!(message, "auto-detect-merchants")
    end

    assert_match(/got a String\); failing closed/, error.message)
  end
end
