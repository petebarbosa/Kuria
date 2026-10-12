require "test_helper"

class AiModelSelectionTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @chat = chats(:one)
  end

  # --- Chat explicit selection ---

  test "chat validates and returns a persisted nonblank ai_model without substitution" do
    Provider::Registry.stubs(:validate_llm_model!)
    @chat.update!(ai_model: "openai/gpt-4o")

    Provider::Registry.expects(:validate_llm_model!).with("openai/gpt-4o")
    Provider::Registry.expects(:llm_default_model).never

    assert_equal "openai/gpt-4o", @chat.reload.effective_ai_model
  end

  test "chat with a blank ai_model resolves to nil and never consults a default" do
    @chat.update!(ai_model: nil)

    Provider::Registry.expects(:llm_default_model).never

    assert_nil @chat.reload.effective_ai_model
  end

  test "chat effective_ai_model does not fall back to a family default_ai_model" do
    # The family-level default was removed: selection is per chat and explicit,
    # so a blank chat model stays blank and the family exposes no model column.
    refute_includes Family.column_names, "default_ai_model"

    assert_nil @chat.reload.ai_model
    assert_nil @chat.effective_ai_model
  end

  test "chat rejects a changed ai_model the registry does not accept" do
    Provider::Registry.stubs(:validate_llm_model!).raises(
      Provider::Registry::Error,
      "Unsupported AI model reference \"bogus\"."
    )

    refute @chat.update(ai_model: "bogus")
    assert_not_empty @chat.errors[:ai_model]
    assert_nil @chat.reload.ai_model
  end

  test "chat skips model validation when the attribute is unchanged" do
    Provider::Registry.expects(:validate_llm_model!).never

    assert @chat.update(title: "Renamed chat")
  end

  # --- Chat.start! snapshotting ---

  test "start! snapshots the explicit model onto the chat and its first user message" do
    Provider::Registry.stubs(:validate_llm_model!)
    Provider::Registry.expects(:llm_default_model).never

    assert_difference -> { @user.chats.count }, 1 do
      chat = @user.chats.start!("Hello there", model: "openai/gpt-4o")

      assert_equal "openai/gpt-4o", chat.ai_model
      assert_equal 1, chat.messages.where(type: "UserMessage").count
      assert_equal "openai/gpt-4o", chat.messages.where(type: "UserMessage").sole.ai_model
    end
  end

  test "start! fails closed and persists nothing when the model is missing" do
    assert_no_difference [ -> { Chat.count }, -> { Message.count } ] do
      assert_raises(ActiveRecord::RecordInvalid) { @user.chats.start!("Hello there", model: "") }
    end
  end

  test "start! fails closed and persists nothing when the registry rejects the model" do
    Provider::Registry.stubs(:validate_llm_model!).raises(Provider::Registry::Error, "Unsupported AI model reference.")

    assert_no_difference [ -> { Chat.count }, -> { Message.count } ] do
      assert_raises(ActiveRecord::RecordInvalid) { @user.chats.start!("Hello there", model: "openai/stale") }
    end
  end

  # --- Message explicit selection ---

  test "user message requires an explicit ai_model" do
    message = @chat.messages.new(type: "UserMessage", content: "Hello", ai_model: nil)

    refute message.valid?
    assert_not_empty message.errors[:ai_model]
  end

  test "assistant message requires an explicit ai_model" do
    message = @chat.messages.new(type: "AssistantMessage", content: "Hi", ai_model: nil)

    refute message.valid?
    assert_not_empty message.errors[:ai_model]
  end
end
