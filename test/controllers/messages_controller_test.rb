require "test_helper"

class MessagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @chat = @user.chats.first

    @redis = Redis.new
    clear_assistant_limits
  end

  teardown do
    clear_assistant_limits
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

  test "counts one accepted message request against the hourly allowance" do
    Provider::Registry.stubs(:validate_llm_model!)

    with_env_overrides ASSISTANT_REQUESTS_PER_HOUR: "5" do
      post chat_messages_url(@chat), params: { message: { content: "Hello", ai_model: "openai/gpt-4o" } }
    end

    assert_redirected_to chat_path(@chat, thinking: true)
    assert_equal "1", @redis.get(AssistantRequestLimiter.redis_key_for(@user))
  end

  test "rejects message creation once the hourly allowance is exhausted" do
    Provider::Registry.stubs(:validate_llm_model!)
    exhaust_assistant_limit!(@user)

    with_env_overrides ASSISTANT_REQUESTS_PER_HOUR: "1" do
      assert_no_difference "Message.count" do
        assert_no_enqueued_jobs only: AssistantResponseJob do
          post chat_messages_url(@chat), params: { message: { content: "Hello", ai_model: "openai/gpt-4o" } }
        end
      end
    end

    assert_redirected_to chats_url
    assert_match(/hourly AI request limit/, flash[:alert])
  end

  test "enforces the allowance in self-hosted mode when AI is available" do
    Provider::Registry.stubs(:validate_llm_model!)
    User.any_instance.stubs(:ai_available?).returns(true)
    exhaust_assistant_limit!(@user)

    with_self_hosting do
      with_env_overrides ASSISTANT_REQUESTS_PER_HOUR: "1" do
        assert_no_difference "Message.count" do
          post chat_messages_url(@chat), params: { message: { content: "Hello", ai_model: "openai/gpt-4o" } }
        end
      end
    end

    assert_redirected_to chats_url
    assert_match(/hourly AI request limit/, flash[:alert])
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
