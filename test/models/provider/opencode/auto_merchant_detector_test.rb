require "test_helper"

class Provider::Opencode::AutoMerchantDetectorTest < ActiveSupport::TestCase
  setup do
    @client = mock("opencode_client")
  end

  test "auto_detect_merchants returns array of AutoDetectedMerchant" do
    transactions = [
      { id: "1", name: "McDonalds", amount: 20, classification: "expense" },
      { id: "2", name: "local pub", amount: 20, classification: "expense" }
    ]
    user_merchants = [ { name: "Shooters" } ]

    session_response = { "id" => "sess_merchant" }
    message_response = {
      "info" => {
        "id" => "msg_merchant",
        "structured_output" => {
          "merchants" => [
            { "transaction_id" => "1", "business_name" => "McDonald's", "business_url" => "mcdonalds.com" },
            { "transaction_id" => "2", "business_name" => "null", "business_url" => "null" }
          ]
        }
      },
      "parts" => []
    }

    @client.expects(:create_session).with(title: "auto-detect-merchants").returns(session_response)
    @client.expects(:send_message).returns(message_response)
    @client.expects(:delete_session).with("sess_merchant")

    detector = Provider::Opencode::AutoMerchantDetector.new(
      @client,
      transactions: transactions,
      user_merchants: user_merchants,
      model: { providerID: "opencode", modelID: "big-pickle" }
    )

    results = detector.auto_detect_merchants

    assert_equal 2, results.size
    assert_equal "McDonald's", results[0].business_name
    assert_equal "mcdonalds.com", results[0].business_url
    assert_nil results[1].business_name
    assert_nil results[1].business_url
  end
end
