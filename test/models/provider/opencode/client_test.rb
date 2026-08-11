require "test_helper"

class Provider::Opencode::ClientTest < ActiveSupport::TestCase
  setup do
    @client = Provider::Opencode::Client.new(
      base_url: "http://localhost:4096",
      password: "test-password"
    )
  end

  test "create_session returns session hash with id" do
    stub_request(:post, "http://localhost:4096/session")
      .with(
        body: { title: "test session" }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
      .to_return(
        status: 200,
        body: { "id" => "sess_123", "title" => "test session" }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    result = @client.create_session(title: "test session")
    assert_equal "sess_123", result["id"]
  end

  test "send_message returns message with info and parts" do
    stub_request(:post, "http://localhost:4096/session/sess_123/message")
      .to_return(
        status: 200,
        body: {
          "info" => {
            "id" => "msg_456",
            "role" => "assistant",
            "model" => { "providerID" => "opencode", "modelID" => "big-pickle" },
            "structured_output" => nil
          },
          "parts" => [
            { "type" => "text", "content" => "Hi there!" }
          ]
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    result = @client.send_message("sess_123",
      content: "Hello",
      model: { providerID: "opencode", modelID: "big-pickle" }
    )

    assert_equal "msg_456", result.dig("info", "id")
    assert_equal "Hi there!", result.dig("parts", 0, "content")
  end

  test "send_message with structured output format" do
    schema = {
      type: "object",
      properties: { name: { type: "string" } },
      required: [ "name" ]
    }

    stub_request(:post, "http://localhost:4096/session/sess_123/message")
      .to_return(
        status: 200,
        body: {
          "info" => {
            "id" => "msg_789",
            "role" => "assistant",
            "structured_output" => { "name" => "test" }
          },
          "parts" => []
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    result = @client.send_message("sess_123",
      content: "Extract name",
      format: { type: "json_schema", schema: schema }
    )

    assert_equal({ "name" => "test" }, result.dig("info", "structured_output"))
  end

  test "list_messages returns array of message objects" do
    stub_request(:get, "http://localhost:4096/session/sess_123/message")
      .to_return(
        status: 200,
        body: [
          { "info" => { "id" => "msg_1", "role" => "user" }, "parts" => [] },
          { "info" => { "id" => "msg_2", "role" => "assistant" }, "parts" => [] }
        ].to_json,
        headers: { "Content-Type" => "application/json" }
      )

    result = @client.list_messages("sess_123")
    assert_equal 2, result.size
    assert_equal "msg_1", result[0].dig("info", "id")
  end

  test "list_providers returns provider data" do
    stub_request(:get, "http://localhost:4096/provider")
      .to_return(
        status: 200,
        body: {
          "all" => [
            { "id" => "opencode", "name" => "MiniMax", "models" => [ { "id" => "big-pickle", "name" => "big-pickle" } ] }
          ],
          "connected" => [ "opencode" ],
          "default" => { "opencode" => "big-pickle" }
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    result = @client.list_providers
    assert_equal "opencode", result.dig("all", 0, "id")
    assert_includes result["connected"], "opencode"
  end

  test "abort_session returns boolean" do
    stub_request(:post, "http://localhost:4096/session/sess_123/abort")
      .to_return(status: 200, body: "true", headers: { "Content-Type" => "application/json" })

    result = @client.abort_session("sess_123")
    assert result
  end

  test "send_message_async returns true" do
    stub_request(:post, "http://localhost:4096/session/sess_123/prompt_async")
      .to_return(status: 204, body: "")

    assert_nothing_raised do
      @client.send_message_async("sess_123", content: "Hello")
    end
  end

  test "client raises on server error" do
    stub_request(:post, "http://localhost:4096/session")
      .to_return(status: 500, body: { "error" => "internal server error" }.to_json, headers: { "Content-Type" => "application/json" })

    assert_raises(Faraday::ServerError) do
      @client.create_session(title: "test")
    end
  end

  test "client sends basic auth header when password provided" do
    stub_request(:get, "http://localhost:4096/provider")
      .with(headers: { "Authorization" => "Basic #{Base64.strict_encode64('opencode:test-password')}" })
      .to_return(status: 200, body: { "all" => [], "connected" => [], "default" => {} }.to_json, headers: { "Content-Type" => "application/json" })

    @client.list_providers
  end
end
