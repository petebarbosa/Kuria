require "test_helper"

class ChatTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @assistant = mock
  end

  test "user sees all messages in debug mode" do
    chat = chats(:one)
    with_env_overrides AI_DEBUG_MODE: "true" do
      assert_equal chat.messages.count, chat.conversation_messages.count
    end
  end

  test "user sees assistant and user messages in normal mode" do
    chat = chats(:one)
    assert_equal 3, chat.conversation_messages.count
  end

  test "start! snapshots an explicit live model onto the chat and its first message" do
    # The Registry performs live membership validation; stub it so the test is
    # deterministic and never reaches the network.
    Provider::Registry.stubs(:validate_llm_model!)

    assert_difference "@user.chats.count", 1 do
      chat = @user.chats.start!("Test prompt", model: "openai/gpt-4o")

      assert_equal "openai/gpt-4o", chat.ai_model
      assert_equal 1, chat.messages.count
      assert_equal 1, chat.messages.where(type: "UserMessage").count
      assert_equal "openai/gpt-4o", chat.messages.where(type: "UserMessage").sole.ai_model
    end
  end

  test "start! persists nothing when the model is missing" do
    # No default substitution: a blank model fails the UserMessage presence
    # validation and the transaction rolls the chat back.
    assert_no_difference [ -> { Chat.count }, -> { Message.count } ] do
      assert_raises(ActiveRecord::RecordInvalid) do
        @user.chats.start!("Test prompt", model: "")
      end
    end
  end

  test "start! persists nothing when the registry rejects the model" do
    Provider::Registry.stubs(:validate_llm_model!).raises(
      Provider::Registry::Error,
      "Unsupported AI model reference \"openai/stale\"."
    )

    assert_no_difference [ -> { Chat.count }, -> { Message.count } ] do
      assert_raises(ActiveRecord::RecordInvalid) do
        @user.chats.start!("Test prompt", model: "openai/stale")
      end
    end
  end
end
