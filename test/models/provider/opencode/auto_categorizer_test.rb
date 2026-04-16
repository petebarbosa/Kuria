require "test_helper"

class Provider::Opencode::AutoCategorizerTest < ActiveSupport::TestCase
  setup do
    @client = mock("opencode_client")
  end

  test "auto_categorize returns array of AutoCategorization" do
    transactions = [
      { id: "1", name: "McDonalds", amount: 20, classification: "expense" },
      { id: "2", name: "Netflix", amount: 10, classification: "expense" }
    ]
    categories = [
      { id: "cat1", name: "Fast Food", classification: "expense" },
      { id: "cat2", name: "Subscriptions", classification: "expense" }
    ]

    session_response = { "id" => "sess_auto" }
    message_response = {
      "info" => {
        "id" => "msg_auto",
        "structured_output" => {
          "categorizations" => [
            { "transaction_id" => "1", "category_name" => "Fast Food" },
            { "transaction_id" => "2", "category_name" => "Subscriptions" }
          ]
        }
      },
      "parts" => []
    }

    @client.expects(:create_session).with(title: "auto-categorize").returns(session_response)
    @client.expects(:send_message).returns(message_response)
    @client.expects(:delete_session).with("sess_auto")

    categorizer = Provider::Opencode::AutoCategorizer.new(
      @client,
      transactions: transactions,
      user_categories: categories,
      model: { providerID: "opencode", modelID: "big-pickle" }
    )

    results = categorizer.auto_categorize

    assert_equal 2, results.size
    assert_equal "1", results[0].transaction_id
    assert_equal "Fast Food", results[0].category_name
    assert_equal "2", results[1].transaction_id
    assert_equal "Subscriptions", results[1].category_name
  end

  test "normalizes null category_name to nil" do
    session_response = { "id" => "sess_auto" }
    message_response = {
      "info" => {
        "id" => "msg_auto",
        "structured_output" => {
          "categorizations" => [
            { "transaction_id" => "1", "category_name" => "null" }
          ]
        }
      },
      "parts" => []
    }

    @client.expects(:create_session).returns(session_response)
    @client.expects(:send_message).returns(message_response)
    @client.expects(:delete_session)

    categorizer = Provider::Opencode::AutoCategorizer.new(
      @client,
      transactions: [{ id: "1", name: "Unknown", amount: 5 }],
      user_categories: [],
      model: { providerID: "opencode", modelID: "big-pickle" }
    )

    results = categorizer.auto_categorize

    assert_nil results[0].category_name
  end
end
