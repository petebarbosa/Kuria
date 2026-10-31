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
    open_chat_panel

    within "#chat-container" do
      assert_selector "h3", text: "Enable Kuria AI"
    end
  end

  test "sidebar shows index when enabled and chats are empty" do
    @user.update!(ai_enabled: true)
    @user.chats.destroy_all

    visit root_url
    open_chat_panel

    within "#chat-container" do
      assert_selector "h1", text: "Chats"
    end
  end

  test "sidebar shows last viewed chat" do
    @user.update!(ai_enabled: true)

    open_chat_panel
    click_on @user.chats.first.title

    # Wait for the frame navigation to record this chat as last viewed.
    within "#chat-container" do
      assert_selector "h1", text: @user.chats.first.title
    end

    # Page refresh
    visit root_url
    open_chat_panel

    # After page refresh, we're still on the last chat we were viewing
    within "#chat-container" do
      assert_selector "h1", text: @user.chats.first.title
    end
  end

  test "create chat and navigate chats sidebar" do
    @user.update!(ai_enabled: true)
    @user.chats.destroy_all

    visit root_url
    open_chat_panel

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
    open_chat_panel

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
    open_chat_panel

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
    open_chat_panel

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
    open_chat_panel

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
    open_chat_panel

    within "#chat-form" do
      assert_selector "p", text: "AI models are unavailable right now"
      assert_no_selector "select[name='chat[ai_model]']"
    end

    assert_no_text "OPENAI_API_KEY"
  end

  test "floating launcher opens the panel without resizing the workspace and close restores focus" do
    @user.update!(ai_enabled: true)

    visit root_url

    launcher = find("[data-chat-panel-target='launcher']")
    assert_no_selector "#ai-chat-panel[open]"

    workspace_width = page.evaluate_script("document.querySelector('main').getBoundingClientRect().width")

    launcher.click
    assert_selector "#ai-chat-panel[open]"
    assert_equal "true", launcher["aria-expanded"]

    open_width = page.evaluate_script("document.querySelector('main').getBoundingClientRect().width")
    assert_in_delta workspace_width, open_width, 0.5

    find("[data-chat-panel-target='close']").click
    assert_no_selector "#ai-chat-panel[open]"
    assert_equal "false", launcher["aria-expanded"]
    assert page.evaluate_script("document.activeElement === document.querySelector('[data-chat-panel-target=\"launcher\"]')")

    closed_width = page.evaluate_script("document.querySelector('main').getBoundingClientRect().width")
    assert_in_delta workspace_width, closed_width, 0.5
  end

  test "escape closes the panel and reopening keeps the same conversation" do
    @user.update!(ai_enabled: true)
    chat = chats(:one)
    @user.update!(last_viewed_chat: chat)

    visit root_url
    open_chat_panel
    within "#chat-container" do
      assert_selector "h1", text: chat.title
    end

    find("#ai-chat-panel").send_keys(:escape)
    assert_no_selector "#ai-chat-panel[open]"
    assert_selector "[data-chat-panel-target='launcher'][aria-expanded='false']"

    open_chat_panel
    within "#chat-container" do
      assert_selector "h1", text: chat.title
    end
  end

  test "chat panel stays open with the same conversation across workspace navigation" do
    @user.update!(ai_enabled: true)
    chat = chats(:one)
    @user.update!(last_viewed_chat: chat)

    visit root_url
    open_chat_panel
    within "#chat-container" do
      assert_selector "h1", text: chat.title
    end

    page.execute_script("Turbo.visit('#{transactions_path}')")

    assert_current_path transactions_path
    assert_selector "#ai-chat-panel[open]"
    within "#chat-container" do
      assert_selector "h1", text: chat.title
    end
  end

  test "chat panel remains modal and keyboard-dismissible after a Turbo navigation" do
    @user.update!(ai_enabled: true)
    @user.update!(last_viewed_chat: chats(:one))

    visit root_url
    open_chat_panel

    page.execute_script("Turbo.visit('#{transactions_path}')")
    assert_current_path transactions_path
    assert_selector "#ai-chat-panel[open]"

    assert_equal true,
      page.evaluate_script("document.querySelector('#ai-chat-panel').matches(':modal')"),
      "expected the chat panel to stay modal after Turbo navigation"

    assert_equal "true",
      find("[data-chat-panel-target='launcher']")["aria-expanded"],
      "expected the launcher to announce the open panel after Turbo navigation"

    page.execute_script("document.querySelector('[data-chat-panel-target=launcher]').focus()")
    assert_equal false,
      page.evaluate_script("document.activeElement === document.querySelector('[data-chat-panel-target=launcher]')"),
      "expected focus to stay contained inside the modal chat panel"

    find("#ai-chat-panel").send_keys(:escape)
    assert_no_selector "#ai-chat-panel[open]"

    open_chat_panel
    assert_equal true,
      page.evaluate_script("document.querySelector('#ai-chat-panel').matches(':modal')"),
      "expected reopening the chat to restore a modal dialog"
  end

  test "long chat history can be scrolled to the last chat inside the panel" do
    @user.update!(ai_enabled: true)
    @user.chats.destroy_all
    @user.update!(last_viewed_chat: nil)

    29.times do |index|
      @user.chats.create!(title: "Synthetic chat #{index + 1}")
    end
    @user.chats.create!(title: "Oldest reachable chat", created_at: 2.days.ago)

    [ [ 390, 844 ], [ 1280, 700 ] ].each do |width, height|
      page.driver.browser.manage.window.resize_to(width, height)
      visit root_url(chat_view: "all")
      open_chat_panel
      assert_selector "#chat-container h1", text: "Chats"

      last_chat = page.evaluate_script(<<~JS)
        (() => {
          const panel = document.querySelector("#ai-chat-panel");
          const link = Array.from(document.querySelectorAll("#chat-container a"))
            .find((candidate) => candidate.textContent.includes("Oldest reachable chat"));
          if (!link) return { found: false };

          // Find the panel's internal history scroller, then scroll it to the
          // end. This is the same element a wheel or touch gesture must move.
          let scroller = link.parentElement;
          let scrollable = false;
          while (scroller && scroller !== document.body) {
            const style = getComputedStyle(scroller);
            if (scroller.scrollHeight > scroller.clientHeight &&
                [ "auto", "scroll" ].includes(style.overflowY)) {
              scroller.scrollTop = scroller.scrollHeight;
              scrollable = true;
              break;
            }
            scroller = scroller.parentElement;
          }

          const row = link.closest(".bg-container") || link;
          const rowBounds = row.getBoundingClientRect();
          const panelBounds = panel.getBoundingClientRect();

          return {
            found: true,
            scrollable,
            visible: rowBounds.top >= panelBounds.top && rowBounds.bottom <= panelBounds.bottom,
            rowTop: rowBounds.top,
            rowBottom: rowBounds.bottom,
            panelTop: panelBounds.top,
            panelBottom: panelBounds.bottom
          };
        })()
      JS

      assert_equal true, last_chat["found"], "expected the last chat row to exist"
      assert_equal true, last_chat["scrollable"],
        "expected the chat history to have an internal scroll container at #{width}x#{height}"
      assert_equal true, last_chat["visible"],
        "expected scrolling to reach the last chat at #{width}x#{height}: #{last_chat.inspect}"
    end
  ensure
    page.driver.browser.manage.window.resize_to(1400, 1400)
  end

  test "panel fills the viewport on a mobile screen" do
    page.driver.browser.manage.window.resize_to(390, 844)
    @user.update!(ai_enabled: true)

    visit root_url
    open_chat_panel

    bounds = page.evaluate_script(<<~JS)
      (() => {
        const rect = document.querySelector("#ai-chat-panel").getBoundingClientRect();
        return {
          x: rect.x,
          y: rect.y,
          width: rect.width,
          height: rect.height,
          viewportWidth: window.innerWidth,
          viewportHeight: window.innerHeight
        };
      })()
    JS

    assert_in_delta 0, bounds["x"], 1
    assert_in_delta 0, bounds["y"], 1
    assert_in_delta bounds["viewportWidth"], bounds["width"], 1
    assert_in_delta bounds["viewportHeight"], bounds["height"], 1
  ensure
    page.driver.browser.manage.window.resize_to(1400, 1400)
  end

  private

    def open_chat_panel
      find("[data-chat-panel-target='launcher']").click
      assert_selector "#ai-chat-panel[open]"

      # Wait for the lazy frame's first render, then finish the entrance
      # animation so clicks and geometry see final bounds.
      assert_selector "turbo-frame#sidebar_chat[complete]"
      page.evaluate_script("document.querySelector('#ai-chat-panel').getAnimations().forEach((animation) => animation.finish())")
    end
end
