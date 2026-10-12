require "test_helper"

class MessagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @chat = @user.chats.first
  end

  test "can create a message" do
    Provider::Registry.stubs(:validate_llm_model!)

    assert_difference "Message.count" do
      post chat_messages_url(@chat), params: { message: { content: "Hello", ai_model: "openai/gpt-4o" } }
    end

    assert_redirected_to chat_path(@chat, thinking: true)
  end

  test "cannot create a message if AI is disabled" do
    @user.update!(ai_enabled: false)

    assert_no_difference "Message.count" do
      post chat_messages_url(@chat), params: { message: { content: "Hello", ai_model: "openai/gpt-4o" } }
    end

    assert_response :forbidden
  end

  test "does not create a message and alerts when the model is missing" do
    assert_no_difference "Message.count" do
      post chat_messages_url(@chat), params: { message: { content: "Hello", ai_model: "" } }
    end

    assert_redirected_to chat_path(@chat)
    assert flash[:alert].present?
  end

  test "does not create a message and alerts when the model cannot be validated" do
    Provider::Registry.stubs(:validate_llm_model!).raises(
      Provider::Registry::Error,
      "Unsupported AI model reference \"openai/stale\"."
    )

    assert_no_difference "Message.count" do
      post chat_messages_url(@chat), params: { message: { content: "Hello", ai_model: "openai/stale" } }
    end

    assert_redirected_to chat_path(@chat)
    assert flash[:alert].present?
  end
end
