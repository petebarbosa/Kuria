require "test_helper"

class Provider::Opencode::ChatResponseParserTest < ActiveSupport::TestCase
  test "parses a basic assistant message response" do
    raw_response = {
      "info" => {
        "id" => "msg_123",
        "role" => "assistant",
        "model" => { "providerID" => "opencode", "modelID" => "minimax-m2.5-free" },
        "structured_output" => nil
      },
      "parts" => [
        { "type" => "text", "content" => "Your net worth is $50,000." }
      ]
    }

    result = Provider::Opencode::ChatResponseParser.new(raw_response).parsed

    assert_equal "msg_123", result.id
    assert_equal "opencode/minimax-m2.5-free", result.model
    assert_equal 1, result.messages.size
    assert_equal "Your net worth is $50,000.", result.messages.first.output_text
    assert_equal 0, result.function_requests.size
  end

  test "parses response with multiple text parts" do
    raw_response = {
      "info" => {
        "id" => "msg_456",
        "role" => "assistant",
        "model" => { "providerID" => "openai", "modelID" => "gpt-4.1" }
      },
      "parts" => [
        { "type" => "text", "content" => "Here is your summary:\n" },
        { "type" => "text", "content" => "You have 3 accounts." }
      ]
    }

    result = Provider::Opencode::ChatResponseParser.new(raw_response).parsed

    assert_equal "openai/gpt-4.1", result.model
    assert_equal 1, result.messages.size
    assert_equal "Here is your summary:\nYou have 3 accounts.", result.messages.first.output_text
  end

  test "parses response with tool_use parts as function requests" do
    raw_response = {
      "info" => {
        "id" => "msg_789",
        "role" => "assistant",
        "model" => { "providerID" => "opencode", "modelID" => "big-pickle" }
      },
      "parts" => [
        {
          "type" => "tool-invocations",
          "toolInvocation" => {
            "toolCallId" => "call_abc",
            "toolName" => "get_accounts",
            "args" => { "family_id" => "fam_123" },
            "state" => "call"
          }
        }
      ]
    }

    result = Provider::Opencode::ChatResponseParser.new(raw_response).parsed

    assert_equal 0, result.messages.size
    assert_equal 1, result.function_requests.size
    assert_equal "call_abc", result.function_requests.first.call_id
    assert_equal "get_accounts", result.function_requests.first.function_name
  end

  test "parses empty response" do
    raw_response = {
      "info" => {
        "id" => "msg_empty",
        "role" => "assistant",
        "model" => { "providerID" => "opencode", "modelID" => "big-pickle" }
      },
      "parts" => []
    }

    result = Provider::Opencode::ChatResponseParser.new(raw_response).parsed

    assert_equal "msg_empty", result.id
    assert_equal 0, result.messages.size
    assert_equal 0, result.function_requests.size
  end

  test "raises InvalidResponseError when given nil response" do
    assert_raises(Provider::Opencode::ChatResponseParser::InvalidResponseError) do
      Provider::Opencode::ChatResponseParser.new(nil).parsed
    end
  end

  test "raises InvalidResponseError when given empty string response" do
    assert_raises(Provider::Opencode::ChatResponseParser::InvalidResponseError) do
      Provider::Opencode::ChatResponseParser.new("").parsed
    end
  end

  test "raises InvalidResponseError when given non-Hash response" do
    assert_raises(Provider::Opencode::ChatResponseParser::InvalidResponseError) do
      Provider::Opencode::ChatResponseParser.new([ "unexpected", "array" ]).parsed
    end
  end
end
