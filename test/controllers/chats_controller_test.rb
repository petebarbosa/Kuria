require "test_helper"

class ChatsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = families(:dylan_family)
    sign_in @user

    @selectable_models = [ [ "OpenAI / gpt-4o", "openai/gpt-4o" ] ]

    # The controller populates the picker through the Registry; stub the live
    # catalog call so these tests never hit the network.
    Provider::Registry.stubs(:llm_selectable_models).returns(@selectable_models)
  end

  test "gets index" do
    get chats_url
    assert_response :success
  end

  test "index populates the RubyLLM model picker" do
    get chats_url

    assert_response :success
    assert controller.instance_variable_get(:@ai_ruby_llm_mode)
    assert_equal @selectable_models, controller.instance_variable_get(:@ai_selectable_models)
    assert_nil controller.instance_variable_get(:@ai_selectable_models_error)
  end

  test "new populates the RubyLLM model picker" do
    get new_chat_url

    assert_response :success
    assert controller.instance_variable_get(:@ai_ruby_llm_mode)
    assert_equal @selectable_models, controller.instance_variable_get(:@ai_selectable_models)
  end

  test "show populates the RubyLLM model picker" do
    get chat_url(chats(:one))

    assert_response :success
    assert controller.instance_variable_get(:@ai_ruby_llm_mode)
    assert_equal @selectable_models, controller.instance_variable_get(:@ai_selectable_models)
  end

  test "fails the live model listing safely without exposing credentials" do
    Provider::Registry.stubs(:llm_selectable_models).raises(
      Provider::Registry::Error,
      "Missing OPENAI_API_KEY for the openai model catalog request. Set OPENAI_API_KEY to check live openai model availability."
    )

    get new_chat_url

    assert_response :success
    assert controller.instance_variable_get(:@ai_ruby_llm_mode)
    assert_empty controller.instance_variable_get(:@ai_selectable_models)
    assert controller.instance_variable_get(:@ai_selectable_models_error)
    assert_match "AI models are unavailable right now", response.body
    assert_no_match(/OPENAI_API_KEY/, response.body)
  end

  test "creates chat" do
    Provider::Registry.stubs(:validate_llm_model!)

    assert_difference("Chat.count") do
      post chats_url, params: { chat: { content: "Hello", ai_model: "openai/gpt-4o" } }
    end

    assert_redirected_to chat_path(Chat.order(created_at: :desc).first, thinking: true)
  end

  test "does not create a chat or message when the model is missing" do
    assert_no_difference [ -> { Chat.count }, -> { Message.count } ] do
      post chats_url, params: { chat: { content: "Hello", ai_model: "" } }
    end

    assert_response :unprocessable_entity
    assert flash[:alert].present?
  end

  test "does not create a chat or message when the model cannot be validated" do
    Provider::Registry.stubs(:validate_llm_model!).raises(
      Provider::Registry::Error,
      "Unsupported AI model reference \"openai/stale\"."
    )

    assert_no_difference [ -> { Chat.count }, -> { Message.count } ] do
      post chats_url, params: { chat: { content: "Hello", ai_model: "openai/stale" } }
    end

    assert_response :unprocessable_entity
    assert flash[:alert].present?
  end

  test "shows chat" do
    get chat_url(chats(:one))
    assert_response :success
  end

  test "destroys chat" do
    assert_difference("Chat.count", -1) do
      delete chat_url(chats(:one))
    end

    assert_redirected_to chats_url
  end

  test "should not allow access to other user's chats" do
    other_user = users(:family_member)
    other_chat = Chat.create!(user: other_user, title: "Other User's Chat")

    get chat_url(other_chat)
    assert_response :not_found

    delete chat_url(other_chat)
    assert_response :not_found
  end
end
