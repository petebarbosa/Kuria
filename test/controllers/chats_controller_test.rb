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

    @redis = Redis.new
    clear_assistant_limits
  end

  teardown do
    clear_assistant_limits
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

  test "counts one accepted chat request against the hourly allowance" do
    Provider::Registry.stubs(:validate_llm_model!)

    with_env_overrides ASSISTANT_REQUESTS_PER_HOUR: "5" do
      post chats_url, params: { chat: { content: "Hello", ai_model: "openai/gpt-4o" } }
    end

    assert_redirected_to chat_path(Chat.order(created_at: :desc).first, thinking: true)
    assert_equal "1", @redis.get(AssistantRequestLimiter.redis_key_for(@user))
  end

  test "rejects chat creation once the hourly allowance is exhausted" do
    Provider::Registry.expects(:validate_llm_model!).never
    exhaust_assistant_limit!(@user)

    with_env_overrides ASSISTANT_REQUESTS_PER_HOUR: "1" do
      assert_no_difference [ -> { Chat.count }, -> { Message.count } ] do
        assert_no_enqueued_jobs only: AssistantResponseJob do
          post chats_url, params: { chat: { content: "Hello", ai_model: "openai/gpt-4o" } }
        end
      end
    end

    assert_redirected_to chats_url
    assert_match(/hourly AI request limit/, flash[:alert])
  end

  test "does not consume the allowance when the message is blank" do
    Provider::Registry.expects(:validate_llm_model!).never

    assert_no_difference [ -> { Chat.count }, -> { Message.count } ] do
      post chats_url, params: { chat: { content: "", ai_model: "openai/gpt-4o" } }
    end

    assert_response :unprocessable_entity
    assert flash[:alert].present?
    assert_nil @redis.get(AssistantRequestLimiter.redis_key_for(@user))
  end

  test "does not consume the allowance when the model cannot be validated" do
    Provider::Registry.stubs(:validate_llm_model!).raises(
      Provider::Registry::Error,
      "Unsupported AI model reference \"openai/stale\"."
    )

    with_env_overrides ASSISTANT_REQUESTS_PER_HOUR: "5" do
      post chats_url, params: { chat: { content: "Hello", ai_model: "openai/stale" } }
    end

    assert_response :unprocessable_entity
    assert_nil @redis.get(AssistantRequestLimiter.redis_key_for(@user))
  end

  test "attributes the allowance to the authenticated user, not another user" do
    Provider::Registry.stubs(:validate_llm_model!)
    exhaust_assistant_limit!(users(:family_member))

    assert_difference "Chat.count" do
      with_env_overrides ASSISTANT_REQUESTS_PER_HOUR: "1" do
        post chats_url, params: { chat: { content: "Hello", ai_model: "openai/gpt-4o" } }
      end
    end

    assert_equal "1", @redis.get(AssistantRequestLimiter.redis_key_for(users(:family_member)))
    assert_equal "1", @redis.get(AssistantRequestLimiter.redis_key_for(@user))
  end

  test "allows a request again once the window resets" do
    Provider::Registry.stubs(:validate_llm_model!)
    exhaust_assistant_limit!(@user)
    @redis.del(AssistantRequestLimiter.redis_key_for(@user))

    assert_difference "Chat.count" do
      with_env_overrides ASSISTANT_REQUESTS_PER_HOUR: "1" do
        post chats_url, params: { chat: { content: "Hello", ai_model: "openai/gpt-4o" } }
      end
    end
  end

  test "rejects a retry without enqueuing when the allowance is exhausted" do
    # Make the chat end with a user message so the retry would queue work and
    # therefore be chargeable.
    chats(:one).messages.where(type: "AssistantMessage").destroy_all
    exhaust_assistant_limit!(@user)

    with_env_overrides ASSISTANT_REQUESTS_PER_HOUR: "1" do
      assert_no_enqueued_jobs only: AssistantResponseJob do
        post retry_chat_url(chats(:one))
      end
    end

    assert_redirected_to chats_url
    assert_match(/hourly AI request limit/, flash[:alert])
  end

  test "counts one accepted retry against the allowance" do
    chats(:one).messages.where(type: "AssistantMessage").destroy_all

    with_env_overrides ASSISTANT_REQUESTS_PER_HOUR: "5" do
      assert_enqueued_jobs 1, only: AssistantResponseJob do
        post retry_chat_url(chats(:one))
      end
    end

    assert_redirected_to chat_path(chats(:one), thinking: true)
    assert_equal "1", @redis.get(AssistantRequestLimiter.redis_key_for(@user))
  end

  test "does not consume the allowance for a no-op retry" do
    # chats(:one) ends with an assistant message, so a retry queues no work and
    # must not be charged.
    assert_no_enqueued_jobs only: AssistantResponseJob do
      post retry_chat_url(chats(:one))
    end

    assert_redirected_to chat_path(chats(:one), thinking: true)
    assert_nil @redis.get(AssistantRequestLimiter.redis_key_for(@user))
  end

  test "does not consume the allowance for another user's chat retry" do
    post retry_chat_url(chats(:two))

    assert_response :not_found
    assert_nil @redis.get(AssistantRequestLimiter.redis_key_for(@user))
  end

  test "redirects with feedback without any work when the limiter is unavailable" do
    Provider::Registry.expects(:validate_llm_model!).never
    AssistantRequestLimiter.stubs(:check).returns(
      AssistantRequestLimiter::Result.new(
        allowed: false, limit: 5, remaining: 0, retry_after: nil, reset_at: nil, reason: :unavailable
      )
    )

    assert_no_difference [ -> { Chat.count }, -> { Message.count } ] do
      assert_no_enqueued_jobs only: AssistantResponseJob do
        post chats_url, params: { chat: { content: "Hello", ai_model: "openai/gpt-4o" } }
      end
    end

    assert_response :see_other
    assert_redirected_to chats_url
    follow_redirect!
    assert_response :success
    assert_match(/temporarily unavailable/, flash[:alert])
    assert_no_match(/redis/i, response.body)
  end

  private
    def clear_assistant_limits
      [ @user, users(:family_member) ].each do |user|
        @redis.del(AssistantRequestLimiter.redis_key_for(user))
      end
    end

    def exhaust_assistant_limit!(user, limit: 1)
      key = AssistantRequestLimiter.redis_key_for(user)
      @redis.set(key, limit.to_s)
      @redis.expire(key, AssistantRequestLimiter::WINDOW_SECONDS)
    end
end
