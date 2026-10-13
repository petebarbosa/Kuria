# frozen_string_literal: true

require "test_helper"

class Api::V1::MessagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.update!(ai_enabled: true)

    @oauth_app = Doorkeeper::Application.create!(
      name: "Test API App",
      redirect_uri: "https://example.com/callback",
      scopes: "read write read_write"
    )

    @write_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read_write"
    )

    @chat = chats(:one)

    @redis = Redis.new
    clear_assistant_limits
  end

  teardown do
    clear_assistant_limits
  end

  test "should require authentication" do
    post "/api/v1/chats/#{@chat.id}/messages"
    assert_response :unauthorized
  end

  test "should require AI to be enabled" do
    @user.update!(ai_enabled: false)

    post "/api/v1/chats/#{@chat.id}/messages",
      params: { content: "Hello" },
      headers: bearer_auth_header(@write_token)
    assert_response :forbidden
  end

  test "should create a message with an explicit live model and write scope" do
    # The Registry validates live model membership; stub it so the test never
    # reaches the network.
    Provider::Registry.stubs(:validate_llm_model!)

    assert_difference "Message.count" do
      post "/api/v1/chats/#{@chat.id}/messages",
        params: { content: "Test message", model: "openai/gpt-4o" },
        headers: bearer_auth_header(@write_token)
    end

    assert_response :created
    response_body = JSON.parse(response.body)
    assert_equal "Test message", response_body["content"]
    assert_equal "user_message", response_body["type"]
    assert_equal "pending", response_body["ai_response_status"]
    assert_equal "openai/gpt-4o", @chat.messages.last.ai_model
  end

  test "should enqueue assistant response job" do
    Provider::Registry.stubs(:validate_llm_model!)

    assert_enqueued_with(job: AssistantResponseJob) do
      post "/api/v1/chats/#{@chat.id}/messages",
        params: { content: "Test message", model: "openai/gpt-4o" },
        headers: bearer_auth_header(@write_token)
    end
  end

  test "enqueues the assistant response exactly once per accepted request" do
    Provider::Registry.stubs(:validate_llm_model!)

    with_env_overrides ASSISTANT_REQUESTS_PER_HOUR: "5" do
      assert_enqueued_jobs 1, only: AssistantResponseJob do
        post "/api/v1/chats/#{@chat.id}/messages",
          params: { content: "Test message", model: "openai/gpt-4o" },
          headers: bearer_auth_header(@write_token)
      end
    end

    assert_response :created
    assert_equal "1", @redis.get(AssistantRequestLimiter.redis_key_for(@user))
  end

  test "should retry last assistant message" do
    skip "Retry functionality needs debugging"

    assistant_message = @chat.messages.create!(
      type: "AssistantMessage",
      content: "Previous response",
      ai_model: "openai/gpt-4o"
    )

    assert_enqueued_with(job: AssistantResponseJob) do
      post "/api/v1/chats/#{@chat.id}/messages/retry",
        headers: bearer_auth_header(@write_token)
    end

    assert_response :accepted
    response_body = JSON.parse(response.body)
    assert response_body["message_id"].present?
  end

  test "should not retry if no assistant message exists" do
    @chat.messages.where(type: "AssistantMessage").destroy_all

    post "/api/v1/chats/#{@chat.id}/messages/retry.json",
      headers: bearer_auth_header(@write_token)

    assert_response :unprocessable_entity
    response_body = JSON.parse(response.body)
    assert_equal "No assistant message to retry", response_body["error"]
  end

  test "should not access messages in other user's chat" do
    other_user = users(:family_member)
    other_user.update!(family: families(:empty))
    other_chat = chats(:two)
    other_chat.update!(user: other_user)

    post "/api/v1/chats/#{other_chat.id}/messages",
      params: { content: "Test" },
      headers: bearer_auth_header(@write_token)

    assert_response :not_found
  end

  test "rejects a missing model before creating a message" do
    assert_no_difference "Message.count" do
      post "/api/v1/chats/#{@chat.id}/messages",
        params: { content: "Hello" },
        headers: bearer_auth_header(@write_token)
    end

    assert_response :unprocessable_entity
    response_body = JSON.parse(response.body)
    assert_equal "provider_configuration_error", response_body["error"]
  end

  test "rejects an unselectable explicit model before creating a message" do
    Provider::Registry.stubs(:validate_llm_model!).raises(
      Provider::Registry::Error,
      "Unsupported AI model reference \"openai/stale\"."
    )

    assert_no_difference "Message.count" do
      post "/api/v1/chats/#{@chat.id}/messages",
        params: { content: "Hello", model: "openai/stale" },
        headers: bearer_auth_header(@write_token)
    end

    assert_response :unprocessable_entity
    response_body = JSON.parse(response.body)
    assert_equal "provider_configuration_error", response_body["error"]
    assert_match(/openai\/stale/, response_body["details"])
  end

  test "rejects message creation with a 429 and no work once the allowance is exhausted" do
    Provider::Registry.stubs(:validate_llm_model!)
    exhaust_assistant_limit!(@user)

    with_env_overrides ASSISTANT_REQUESTS_PER_HOUR: "1" do
      assert_no_difference "Message.count" do
        assert_no_enqueued_jobs only: AssistantResponseJob do
          post "/api/v1/chats/#{@chat.id}/messages",
            params: { content: "Test message", model: "openai/gpt-4o" },
            headers: bearer_auth_header(@write_token)
        end
      end
    end

    assert_response :too_many_requests
    assert response.headers["Retry-After"].present?
    body = JSON.parse(response.body)
    assert_equal "rate_limit_exceeded", body["error"]
  end

  test "does not consume the allowance when the model cannot be validated" do
    Provider::Registry.stubs(:validate_llm_model!).raises(
      Provider::Registry::Error,
      "Unsupported AI model reference \"openai/stale\"."
    )

    with_env_overrides ASSISTANT_REQUESTS_PER_HOUR: "5" do
      post "/api/v1/chats/#{@chat.id}/messages",
        params: { content: "Hello", model: "openai/stale" },
        headers: bearer_auth_header(@write_token)
    end

    assert_response :unprocessable_entity
    assert_nil @redis.get(AssistantRequestLimiter.redis_key_for(@user))
  end

  test "counts one accepted retry against the allowance" do
    # The retry action is gated before any storage mutation. Its own persistence
    # path is covered elsewhere; here we assert the admission is attributed and
    # counted once even though the request proceeds to the existing retry logic.
    with_env_overrides ASSISTANT_REQUESTS_PER_HOUR: "5" do
      post "/api/v1/chats/#{@chat.id}/messages/retry",
        headers: bearer_auth_header(@write_token)
    end

    assert_equal "1", @redis.get(AssistantRequestLimiter.redis_key_for(@user))
  end

  test "rejects retry with a 429 and no work once the allowance is exhausted" do
    exhaust_assistant_limit!(@user)

    with_env_overrides ASSISTANT_REQUESTS_PER_HOUR: "1" do
      assert_no_difference "Message.count" do
        assert_no_enqueued_jobs only: AssistantResponseJob do
          post "/api/v1/chats/#{@chat.id}/messages/retry",
            headers: bearer_auth_header(@write_token)
        end
      end
    end

    assert_response :too_many_requests
    body = JSON.parse(response.body)
    assert_equal "rate_limit_exceeded", body["error"]
  end

  test "enforces the allowance in self-hosted mode when AI is available" do
    Provider::Registry.stubs(:validate_llm_model!)
    User.any_instance.stubs(:ai_available?).returns(true)
    exhaust_assistant_limit!(@user)

    with_self_hosting do
      with_env_overrides ASSISTANT_REQUESTS_PER_HOUR: "1" do
        assert_no_difference "Message.count" do
          post "/api/v1/chats/#{@chat.id}/messages",
            params: { content: "Test message", model: "openai/gpt-4o" },
            headers: bearer_auth_header(@write_token)
        end
      end
    end

    assert_response :too_many_requests
  end

  private

    def bearer_auth_header(token)
      { "Authorization" => "Bearer #{token.token}" }
    end

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
