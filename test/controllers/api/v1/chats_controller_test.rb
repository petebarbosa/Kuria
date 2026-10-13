# frozen_string_literal: true

require "test_helper"

class Api::V1::ChatsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.update!(ai_enabled: true)

    @oauth_app = Doorkeeper::Application.create!(
      name: "Test API App",
      redirect_uri: "https://example.com/callback",
      scopes: "read write read_write"
    )

    @read_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read"
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
    get "/api/v1/chats"
    assert_response :unauthorized
  end

  test "should require AI to be enabled" do
    @user.update!(ai_enabled: false)

    get "/api/v1/chats", headers: bearer_auth_header(@read_token)
    assert_response :forbidden

    response_body = JSON.parse(response.body)
    assert_equal "feature_disabled", response_body["error"]
  end

  test "should list chats with read scope" do
    get "/api/v1/chats", headers: bearer_auth_header(@read_token)
    assert_response :success

    response_body = JSON.parse(response.body)
    assert response_body["chats"].is_a?(Array)
    assert response_body["pagination"].present?
  end

  test "should show chat with messages" do
    get "/api/v1/chats/#{@chat.id}", headers: bearer_auth_header(@read_token)
    assert_response :success

    response_body = JSON.parse(response.body)
    assert_equal @chat.id, response_body["id"]
    assert response_body["messages"].is_a?(Array)
  end

  test "should create a chat with an explicit live model and write scope" do
    # The Registry validates live model membership; stub it so the test never
    # reaches the network.
    Provider::Registry.stubs(:validate_llm_model!)

    assert_difference [ "Chat.count", "Message.count" ] do
      post "/api/v1/chats",
        params: { title: "New chat", message: "Hello AI", model: "openai/gpt-4o" },
        headers: bearer_auth_header(@write_token)
    end

    assert_response :created
    response_body = JSON.parse(response.body)
    assert_equal "New chat", response_body["title"]
    assert_equal "openai/gpt-4o", Message.last.ai_model
  end

  test "should create a chat without an initial message" do
    assert_difference "Chat.count" do
      post "/api/v1/chats",
        params: { title: "Empty chat" },
        headers: bearer_auth_header(@write_token)
    end

    assert_response :created
    assert_equal "Empty chat", JSON.parse(response.body)["title"]
  end

  test "should not create chat with read scope" do
    post "/api/v1/chats",
      params: { title: "New chat" },
      headers: bearer_auth_header(@read_token)

    assert_response :forbidden
  end

  test "rejects a missing model before creating a chat or message" do
    assert_no_difference [ "Chat.count", "Message.count" ] do
      post "/api/v1/chats",
        params: { title: "New chat", message: "Hello AI" },
        headers: bearer_auth_header(@write_token)
    end

    assert_response :unprocessable_entity
    response_body = JSON.parse(response.body)
    assert_equal "provider_configuration_error", response_body["error"]
  end

  test "rejects an unselectable explicit model before creating a chat or message" do
    Provider::Registry.stubs(:validate_llm_model!).raises(
      Provider::Registry::Error,
      "Unsupported AI model reference \"openai/stale\"."
    )

    assert_no_difference [ "Chat.count", "Message.count" ] do
      post "/api/v1/chats",
        params: { title: "New chat", message: "Hello AI", model: "openai/stale" },
        headers: bearer_auth_header(@write_token)
    end

    assert_response :unprocessable_entity
    response_body = JSON.parse(response.body)
    assert_equal "provider_configuration_error", response_body["error"]
    assert_match(/openai\/stale/, response_body["details"])
  end

  test "should update chat" do
    patch "/api/v1/chats/#{@chat.id}",
      params: { title: "Updated title" },
      headers: bearer_auth_header(@write_token)

    assert_response :success
    response_body = JSON.parse(response.body)
    assert_equal "Updated title", response_body["title"]
  end

  test "should delete chat" do
    assert_difference "Chat.count", -1 do
      delete "/api/v1/chats/#{@chat.id}", headers: bearer_auth_header(@write_token)
    end

    assert_response :no_content
  end

  test "should not access other user's chat" do
    other_user = users(:family_member)
    other_user.update!(family: families(:empty))
    other_chat = chats(:two)
    other_chat.update!(user: other_user)

    get "/api/v1/chats/#{other_chat.id}", headers: bearer_auth_header(@read_token)
    assert_response :not_found
  end

  test "should support API key authentication" do
    @user.api_keys.destroy_all

    plain_key = ApiKey.generate_secure_key
    api_key = @user.api_keys.build(
      name: "Test API Key",
      scopes: [ "read_write" ]
    )
    api_key.key = plain_key
    api_key.save!

    # API key auth consults the Redis-backed rate limiter; route to the real
    # no-op limiter so this focused test runs without a Redis service while
    # still exercising API key authentication.
    ApiRateLimiter.stubs(:limit).returns(NoopApiRateLimiter.new(api_key))

    get "/api/v1/chats", headers: { "X-Api-Key" => plain_key }
    assert_response :success
  end

  test "attributes an API key chat request to the key owner" do
    @user.api_keys.destroy_all

    plain_key = ApiKey.generate_secure_key
    api_key = @user.api_keys.build(name: "Write Key", scopes: [ "read_write" ])
    api_key.key = plain_key
    api_key.save!

    ApiRateLimiter.stubs(:limit).returns(NoopApiRateLimiter.new(api_key))
    Provider::Registry.stubs(:validate_llm_model!)

    with_env_overrides ASSISTANT_REQUESTS_PER_HOUR: "5" do
      post "/api/v1/chats",
        params: { title: "New chat", message: "Hello AI", model: "openai/gpt-4o" },
        headers: { "X-Api-Key" => plain_key }
    end

    assert_response :created
    assert_equal "1", @redis.get(AssistantRequestLimiter.redis_key_for(@user))
  end

  test "counts one accepted chat request per accepted request without double-enqueuing" do
    Provider::Registry.stubs(:validate_llm_model!)

    with_env_overrides ASSISTANT_REQUESTS_PER_HOUR: "5" do
      assert_enqueued_jobs 1, only: AssistantResponseJob do
        post "/api/v1/chats",
          params: { title: "New chat", message: "Hello AI", model: "openai/gpt-4o" },
          headers: bearer_auth_header(@write_token)
      end
    end

    assert_response :created
    assert_equal "1", @redis.get(AssistantRequestLimiter.redis_key_for(@user))
  end

  test "rejects chat creation with a 429 and no work once the allowance is exhausted" do
    Provider::Registry.stubs(:validate_llm_model!)
    exhaust_assistant_limit!(@user)

    with_env_overrides ASSISTANT_REQUESTS_PER_HOUR: "1" do
      assert_no_difference [ "Chat.count", "Message.count" ] do
        assert_no_enqueued_jobs only: AssistantResponseJob do
          post "/api/v1/chats",
            params: { title: "New chat", message: "Hello AI", model: "openai/gpt-4o" },
            headers: bearer_auth_header(@write_token)
        end
      end
    end

    assert_response :too_many_requests
    assert response.headers["Retry-After"].present?
    body = JSON.parse(response.body)
    assert_equal "rate_limit_exceeded", body["error"]
    assert_equal 1, body.dig("details", "limit")
  end

  test "does not consume the allowance when the model cannot be validated" do
    Provider::Registry.stubs(:validate_llm_model!).raises(
      Provider::Registry::Error,
      "Unsupported AI model reference \"openai/stale\"."
    )

    with_env_overrides ASSISTANT_REQUESTS_PER_HOUR: "5" do
      post "/api/v1/chats",
        params: { title: "New chat", message: "Hello AI", model: "openai/stale" },
        headers: bearer_auth_header(@write_token)
    end

    assert_response :unprocessable_entity
    assert_nil @redis.get(AssistantRequestLimiter.redis_key_for(@user))
  end

  test "attributes the allowance to the authenticated token owner" do
    Provider::Registry.stubs(:validate_llm_model!)
    exhaust_assistant_limit!(users(:family_member))

    assert_difference "Chat.count" do
      with_env_overrides ASSISTANT_REQUESTS_PER_HOUR: "1" do
        post "/api/v1/chats",
          params: { title: "New chat", message: "Hello AI", model: "openai/gpt-4o" },
          headers: bearer_auth_header(@write_token)
      end
    end

    assert_equal "1", @redis.get(AssistantRequestLimiter.redis_key_for(@user))
  end

  test "reports a 503 without work when the limiter is unavailable" do
    Provider::Registry.stubs(:validate_llm_model!)
    AssistantRequestLimiter.stubs(:admit).returns(
      AssistantRequestLimiter::Result.new(
        allowed: false, limit: 5, remaining: 0, retry_after: nil, reset_at: nil, reason: :unavailable
      )
    )

    assert_no_difference [ "Chat.count", "Message.count" ] do
      assert_no_enqueued_jobs only: AssistantResponseJob do
        post "/api/v1/chats",
          params: { title: "New chat", message: "Hello AI", model: "openai/gpt-4o" },
          headers: bearer_auth_header(@write_token)
      end
    end

    assert_response :service_unavailable
    body = JSON.parse(response.body)
    assert_equal "service_unavailable", body["error"]
    assert_no_match(/redis/i, response.body)
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
