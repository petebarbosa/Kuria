require "test_helper"

class Provider::OpencodeTest < ActiveSupport::TestCase
  include ProviderTestHelper

  setup do
    @client = mock("opencode_client")
    Provider::Opencode::Client.stubs(:new).returns(@client)
    @provider = Provider::Opencode.new
  end

  test "supports canonical opencode references in provider/model format" do
    assert @provider.supports_model?("opencode/big-pickle")
    assert @provider.supports_model?("opencode/minimax-m2.5-free")
  end

  test "rejects foreign, malformed, blank, and unprefixed model references" do
    refute @provider.supports_model?("openai/gpt-4o")
    refute @provider.supports_model?("opencode_go/grok-4-fast")
    refute @provider.supports_model?("anthropic/claude-3-5-sonnet")
    refute @provider.supports_model?("gpt-4o")
    refute @provider.supports_model?("opencode/")
    refute @provider.supports_model?("/model")
    refute @provider.supports_model?("")
    refute @provider.supports_model?(nil)
  end

  test "chat_response creates session and sends message" do
    session_response = { "id" => "sess_chat" }
    message_response = {
      "info" => {
        "id" => "msg_chat",
        "role" => "assistant",
        "model" => { "providerID" => "opencode", "modelID" => "big-pickle" }
      },
      "parts" => [
        { "type" => "text", "content" => "Your net worth is $50,000." }
      ]
    }

    @client.expects(:create_session).with(title: anything).returns(session_response)
    @client.expects(:send_message).with(
      "sess_chat",
      content: "What is my net worth?",
      model: { providerID: "opencode", modelID: "big-pickle" },
      system: "You are a helpful assistant."
    ).returns(message_response)

    response = @provider.chat_response(
      "What is my net worth?",
      model: "opencode/big-pickle",
      instructions: "You are a helpful assistant."
    )

    assert response.success?
    assert_equal "msg_chat", response.data.id
    assert_equal 1, response.data.messages.size
    assert_equal "Your net worth is $50,000.", response.data.messages.first.output_text
  end

  test "chat_response reuses existing opencode_session_id" do
    message_response = {
      "info" => {
        "id" => "msg_reuse",
        "role" => "assistant",
        "model" => { "providerID" => "opencode", "modelID" => "big-pickle" }
      },
      "parts" => [
        { "type" => "text", "content" => "Reused session response." }
      ]
    }

    @client.expects(:create_session).never
    @client.expects(:send_message).with(
      "existing_sess_123",
      content: "Hello",
      model: { providerID: "opencode", modelID: "big-pickle" },
      system: nil
    ).returns(message_response)

    response = @provider.chat_response(
      "Hello",
      model: "opencode/big-pickle",
      previous_response_id: "existing_sess_123"
    )

    assert response.success?
    assert_equal "Reused session response.", response.data.messages.first.output_text
  end

  test "chat_response with streamer emits text chunks" do
    session_response = { "id" => "sess_stream" }
    message_response = {
      "info" => {
        "id" => "msg_stream",
        "role" => "assistant",
        "model" => { "providerID" => "opencode", "modelID" => "big-pickle" }
      },
      "parts" => [
        { "type" => "text", "content" => "Hello world" }
      ]
    }

    @client.expects(:create_session).returns(session_response)
    @client.expects(:send_message).returns(message_response)

    collected_chunks = []
    streamer = proc { |chunk| collected_chunks << chunk }

    response = @provider.chat_response(
      "Hello",
      model: "opencode/big-pickle",
      streamer: streamer
    )

    assert response.success?
    text_chunks = collected_chunks.select { |c| c.type == "output_text" }
    response_chunks = collected_chunks.select { |c| c.type == "response" }
    assert text_chunks.size >= 1
    assert_equal 1, response_chunks.size
  end

  test "chat_response wraps errors in provider response" do
    @client.expects(:create_session).raises(Faraday::ConnectionFailed.new("connection refused"))

    response = @provider.chat_response(
      "Hello",
      model: "opencode/big-pickle"
    )

    refute response.success?
    assert_kind_of Provider::Opencode::Error, response.error
  end

  test "chat_response wraps client InvalidResponseError in provider Error" do
    session_response = { "id" => "sess_err" }
    @client.expects(:create_session).returns(session_response)
    @client.expects(:send_message).raises(
      Provider::Opencode::Client::InvalidResponseError,
      "expected Hash, got NilClass"
    )

    response = @provider.chat_response(
      "Hello",
      model: "invalid/model"
    )

    refute response.success?
    assert_kind_of Provider::Opencode::Error, response.error
    assert_match(/OpenCode API response error/, response.error.message)
    assert_equal "invalid/model", response.error.details[:model]
    assert_equal "sess_err", response.error.details[:session_id]
  end

  test "chat_response wraps parser InvalidResponseError in provider Error" do
    session_response = { "id" => "sess_parse_err" }
    @client.expects(:create_session).returns(session_response)
    @client.expects(:send_message).returns(nil)

    response = @provider.chat_response(
      "Hello",
      model: "opencode/big-pickle"
    )

    refute response.success?
    assert_kind_of Provider::Opencode::Error, response.error
    assert_match(/OpenCode API response error/, response.error.message)
  end

  test "auto_categorize delegates to AutoCategorizer" do
    expected_results = [
      Provider::LlmConcept::AutoCategorization.new(transaction_id: "1", category_name: "Food")
    ]

    Provider::Opencode::AutoCategorizer.any_instance
      .expects(:auto_categorize)
      .returns(expected_results)

    response = @provider.auto_categorize(
      transactions: [ { id: "1", name: "McDonalds" } ],
      user_categories: [ { name: "Food" } ]
    )

    assert response.success?
    assert_equal 1, response.data.size
    assert_equal "Food", response.data.first.category_name
  end

  test "auto_detect_merchants delegates to AutoMerchantDetector" do
    expected_results = [
      Provider::LlmConcept::AutoDetectedMerchant.new(
        transaction_id: "1",
        business_name: "McDonald's",
        business_url: "mcdonalds.com"
      )
    ]

    Provider::Opencode::AutoMerchantDetector.any_instance
      .expects(:auto_detect_merchants)
      .returns(expected_results)

    response = @provider.auto_detect_merchants(
      transactions: [ { id: "1", name: "McDonalds" } ],
      user_merchants: []
    )

    assert response.success?
    assert_equal "McDonald's", response.data.first.business_name
  end
end
