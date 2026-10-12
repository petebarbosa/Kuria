require "application_system_test_case"

class ChatsTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)

    # The chat form builds its picker from the live RubyLLM catalog. Stub the
    # registry boundary before any page (including login) renders the lazy chat
    # frame, so these system tests never touch a provider network. Model
    # validation is stubbed too, so an explicit selection persists without a
    # live membership request.
    @live_models = [
      [ "OpenAI / gpt-4o", "openai/gpt-4o" ],
      [ "OpenCode Go / kimi-k3", "opencode_go/kimi-k3" ]
    ]
    Provider::Registry.stubs(:llm_selectable_models).returns(@live_models)
    Provider::Registry.stubs(:validate_llm_model!)

    login_as(@user)
  end

  test "sidebar shows consent if ai is disabled for user" do
    @user.update!(ai_enabled: false)

    visit root_path

    within "#chat-container" do
      assert_selector "h3", text: "Enable Kuria AI"
    end
  end

  test "sidebar shows index when enabled and chats are empty" do
    @user.update!(ai_enabled: true)
    @user.chats.destroy_all

    visit root_url

    within "#chat-container" do
      assert_selector "h1", text: "Chats"
    end
  end

  test "sidebar shows last viewed chat" do
    @user.update!(ai_enabled: true)

    click_on @user.chats.first.title

    # Page refresh
    visit root_url

    # After page refresh, we're still on the last chat we were viewing
    within "#chat-container" do
      assert_selector "h1", text: @user.chats.first.title
    end
  end

  test "create chat and navigate chats sidebar" do
    @user.update!(ai_enabled: true)
    @user.chats.destroy_all

    visit root_url

    Chat.any_instance.expects(:ask_assistant_later).once

    within "#chat-form" do
      fill_in "chat[content]", with: "Can you help with my finances?"
      select "OpenAI / gpt-4o", from: "chat[ai_model]"
      find("button[type='submit']").click
    end

    assert_text "Can you help with my finances?"

    find("#chat-nav-back").click

    assert_selector "h1", text: "Chats"

    click_on @user.chats.reload.first.title

    assert_text "Can you help with my finances?"
  end

  test "chat form requires an explicit live selection and renders no hidden default" do
    @user.update!(ai_enabled: true)
    @user.chats.destroy_all

    visit root_url

    within "#chat-form" do
      select = find("select[name='chat[ai_model]']")

      # No automatic choice: a blank prompt is offered and nothing is preselected.
      assert_equal "Choose a model", select.find("option[value='']").text
      assert_equal "", select.value

      # Only the live models are selectable.
      assert_selector "option[value='openai/gpt-4o']", text: "OpenAI / gpt-4o"
      assert_selector "option[value='opencode_go/kimi-k3']", text: "OpenCode Go / kimi-k3"

      # The legacy hidden deployment default is gone.
      assert_no_selector "input[name='chat[ai_model]']", visible: :all
    end
  end

  test "chat form selects the persisted model only while it is still live" do
    @user.update!(ai_enabled: true)

    chat = chats(:one)
    chat.update_column(:ai_model, "opencode_go/kimi-k3")
    @user.update!(last_viewed_chat: chat)

    visit root_url

    within "#chat-form" do
      assert_equal "opencode_go/kimi-k3", find("select[name='message[ai_model]']").value
      assert_no_text "no longer available"
    end
  end

  test "chat form clears a persisted model that is no longer live without substituting one" do
    @user.update!(ai_enabled: true)

    chat = chats(:one)
    chat.update_column(:ai_model, "openai/retired-model")
    @user.update!(last_viewed_chat: chat)

    visit root_url

    within "#chat-form" do
      # The stale model is neither preselected nor silently replaced.
      assert_equal "", find("select[name='message[ai_model]']").value
      assert_no_selector "option[value='openai/retired-model'][selected]", visible: :all
      assert_text "Your previously selected model is no longer available"
    end
  end

  test "submitting the chat persists the explicitly selected live model" do
    @user.update!(ai_enabled: true)

    chat = chats(:one)
    chat.update_column(:ai_model, "opencode_go/kimi-k3")
    @user.update!(last_viewed_chat: chat)

    visit root_url

    Chat.any_instance.expects(:ask_assistant_later).once

    within "#chat-form" do
      fill_in "message[content]", with: "What is my net worth?"
      select "OpenAI / gpt-4o", from: "message[ai_model]"
      find("button[type='submit']").click
    end

    assert_text "What is my net worth?"
    assert_equal "openai/gpt-4o", chat.messages.reload.where(type: "UserMessage").last.ai_model
  end

  test "chat form shows a credential-agnostic message when the live listing fails" do
    @user.update!(ai_enabled: true)
    @user.chats.destroy_all

    Provider::Registry.unstub(:llm_selectable_models)
    Provider::Registry.stubs(:llm_selectable_models).raises(
      Provider::Registry::Error,
      "Missing OPENAI_API_KEY for the live openai model catalog request."
    )

    visit root_url

    within "#chat-form" do
      assert_selector "p", text: "AI models are unavailable right now"
      assert_no_selector "select[name='chat[ai_model]']"
    end

    assert_no_text "OPENAI_API_KEY"
  end
end
