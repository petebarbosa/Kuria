require "test_helper"

class AssistantAuditOwnerTest < ActiveSupport::TestCase
  setup do
    @chat = chats(:one)
  end

  test "allows empty pending and failed assistant audit owners but not empty complete assistants" do
    pending_owner = AssistantMessage.new(
      chat: @chat, content: "", ai_model: "openai/gpt-4o", status: :pending
    )
    assert_predicate pending_owner, :valid?

    failed_owner = AssistantMessage.new(
      chat: @chat, content: "", ai_model: "openai/gpt-4o", status: :failed
    )
    assert_predicate failed_owner, :valid?

    complete_message = AssistantMessage.new(
      chat: @chat, content: "", ai_model: "openai/gpt-4o", status: :complete
    )
    assert_not_predicate complete_message, :valid?
    assert_includes complete_message.errors[:content], "can't be blank"

    complete_with_content = AssistantMessage.new(
      chat: @chat, content: "Finished answer", ai_model: "openai/gpt-4o", status: :complete
    )
    assert_predicate complete_with_content, :valid?
  end

  test "user and developer messages still require content" do
    user_message = UserMessage.new(chat: @chat, content: "", ai_model: "openai/gpt-4o")
    assert_not_predicate user_message, :valid?
    assert_includes user_message.errors[:content], "can't be blank"

    valid_user_message = UserMessage.new(chat: @chat, content: "Hello", ai_model: "openai/gpt-4o")
    assert_predicate valid_user_message, :valid?

    developer_message = DeveloperMessage.new(chat: @chat, content: "")
    assert_not_predicate developer_message, :valid?
    assert_includes developer_message.errors[:content], "can't be blank"
  end

  test "visibility scope excludes only failed and empty pending assistant owners" do
    pending_empty = create_owner(status: :pending, content: "")
    pending_whitespace = create_owner(status: :pending, content: "   ")
    pending_visible = create_owner(status: :pending, content: "Visible partial")
    failed_empty = create_owner(status: :failed, content: "")
    failed_with_content = create_owner(status: :failed, content: "Hidden failure detail")
    complete_message = create_owner(status: :complete, content: "Complete answer")
    user_message = @chat.messages.create!(
      type: "UserMessage", content: "A question", ai_model: "openai/gpt-4o"
    )
    developer_message = @chat.messages.create!(
      type: "DeveloperMessage", content: "Developer instructions"
    )

    visible_ids = @chat.messages.visible_in_conversation.pluck(:id)

    assert_includes visible_ids, pending_visible.id
    assert_includes visible_ids, complete_message.id
    assert_includes visible_ids, user_message.id
    assert_includes visible_ids, developer_message.id
    refute_includes visible_ids, pending_empty.id
    refute_includes visible_ids, pending_whitespace.id
    refute_includes visible_ids, failed_empty.id
    refute_includes visible_ids, failed_with_content.id
  end

  test "normal conversation view excludes audit owners and keeps developer messages out" do
    developer_message = @chat.messages.create!(
      type: "DeveloperMessage", content: "Developer instructions"
    )
    pending_empty = create_owner(status: :pending, content: "")
    failed_owner = create_owner(status: :failed, content: "Hidden failure")
    pending_visible = create_owner(status: :pending, content: "Visible partial")

    conversation = @chat.conversation_messages

    assert_includes conversation, pending_visible
    refute_includes conversation, pending_empty
    refute_includes conversation, failed_owner
    refute_includes conversation, developer_message
  end

  test "debug conversation view keeps developer messages but still excludes audit owners" do
    developer_message = @chat.messages.create!(
      type: "DeveloperMessage", content: "Developer instructions"
    )
    pending_empty = create_owner(status: :pending, content: "")
    failed_owner = create_owner(status: :failed, content: "Hidden failure")
    pending_visible = create_owner(status: :pending, content: "Visible partial")

    with_env_overrides AI_DEBUG_MODE: "true" do
      conversation = @chat.conversation_messages

      assert_includes conversation, developer_message
      assert_includes conversation, pending_visible
      refute_includes conversation, pending_empty
      refute_includes conversation, failed_owner
    end
  end

  test "retry eligibility ignores failed and blank pending audit owners" do
    chat = chats(:two)
    AssistantMessage.create!(
      chat: chat, content: "", ai_model: "openai/gpt-4o", status: :pending
    )
    AssistantMessage.create!(
      chat: chat, content: "", ai_model: "openai/gpt-4o", status: :failed
    )

    assert_predicate chat, :needs_assistant_response?

    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    chat.retry_last_message!

    enqueued = ActiveJob::Base.queue_adapter.enqueued_jobs
    assert_equal 1, enqueued.size
    assert_equal "AssistantResponseJob", enqueued.first["job_class"]
  end

  test "audit-only creates do not broadcast" do
    assert_no_turbo_stream_broadcasts @chat do
      create_owner(status: :pending, content: "")
      create_owner(status: :pending, content: "   ")
      create_owner(status: :failed, content: "")
      create_owner(status: :failed, content: "Hidden failure")
    end
  end

  test "audit-only updates do not broadcast" do
    pending_owner = create_owner(status: :pending, content: "")
    failed_owner = create_owner(status: :failed, content: "Hidden failure")

    assert_no_turbo_stream_broadcasts @chat do
      pending_owner.update!(provider_id: "audit-owner")
      failed_owner.update!(content: "Still hidden")
    end
  end

  test "failure status transitions never broadcast" do
    owner = create_owner(status: :pending, content: "Visible partial")

    streams = capture_turbo_stream_broadcasts(@chat) do
      owner.update!(status: :failed)
    end
    assert_empty streams

    streams = capture_turbo_stream_broadcasts(@chat) do
      owner.update!(content: "Late failure detail")
    end
    assert_empty streams

    blank_owner = create_owner(status: :pending, content: "")
    streams = capture_turbo_stream_broadcasts(@chat) do
      blank_owner.update!(content: "Never visible", status: :failed)
    end
    assert_empty streams
  end

  test "pending assistant owners containing only unicode whitespace stay hidden and retryable" do
    chat = chats(:two)
    whitespace_contents = [
      "\n",
      "\t",
      "\r\n",
      " \t\n ",
      "\u0085",
      "\u00A0",
      "\u1680",
      "\u2007",
      "\u202F",
      "\u3000"
    ]

    owners = whitespace_contents.map do |content|
      AssistantMessage.create!(
        chat: chat,
        content: content,
        ai_model: "openai/gpt-4o",
        status: :pending
      )
    end

    visible_ids = chat.messages.visible_in_conversation.pluck(:id)
    conversation = chat.conversation_messages

    owners.each do |owner|
      refute_includes visible_ids, owner.id
      refute_includes conversation, owner
    end

    assert_predicate chat, :needs_assistant_response?,
      "hidden whitespace-only audit owners must not block the retry gate"
  end

  test "first visible content on a pending audit owner appends once then updates" do
    owner = create_owner(status: :pending, content: "")

    streams = capture_turbo_stream_broadcasts(@chat) do
      owner.update!(content: "Hello")
    end
    assert_equal 1, streams.size
    assert_equal "append", streams.first["action"]
    assert_equal "messages", streams.first["target"]

    streams = capture_turbo_stream_broadcasts(@chat) do
      owner.update!(content: "Hello world")
    end
    assert_equal 1, streams.size
    assert_equal "update", streams.first["action"]
    assert_equal "assistant_message_#{owner.id}", streams.first["target"]
  end

  test "finalizing a pending audit owner with its first content appends once" do
    owner = create_owner(status: :pending, content: "")

    streams = capture_turbo_stream_broadcasts(@chat) do
      owner.update!(content: "Final answer", status: :complete)
    end

    assert_equal 1, streams.size
    assert_equal "append", streams.first["action"]
    assert_equal "messages", streams.first["target"]
  end

  test "ordinary assistant streaming still appends on creation and updates later chunks" do
    owner = nil

    streams = capture_turbo_stream_broadcasts(@chat) do
      owner = create_owner(status: :complete, content: "Alpha")
      owner.append_text!(" Beta")
    end

    assert_equal %w[append update], streams.map { |stream| stream["action"] }
    assert_equal "messages", streams.first["target"]
    assert_equal "assistant_message_#{owner.id}", streams.last["target"]
  end

  private
    def create_owner(status:, content:)
      AssistantMessage.create!(
        chat: @chat,
        content: content,
        ai_model: "openai/gpt-4o",
        status: status
      )
    end
end

class AssistantAuditOwnerApiTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.update!(ai_enabled: true)
    @chat = chats(:one)

    application = Doorkeeper::Application.create!(
      name: "Assistant audit owner test",
      redirect_uri: "https://example.com/callback",
      scopes: "read write read_write"
    )

    @token = Doorkeeper::AccessToken.create!(
      application: application,
      resource_owner_id: @user.id,
      scopes: "read"
    )
  end

  test "show paginates only visible messages while preserving developer exposure" do
    pending_empty = @chat.messages.create!(
      type: "AssistantMessage", content: "", ai_model: "openai/gpt-4o", status: :pending
    )
    failed_owner = @chat.messages.create!(
      type: "AssistantMessage", content: "Hidden failure", ai_model: "openai/gpt-4o", status: :failed
    )
    pending_visible = @chat.messages.create!(
      type: "AssistantMessage", content: "Visible partial", ai_model: "openai/gpt-4o", status: :pending
    )

    get "/api/v1/chats/#{@chat.id}", headers: { "Authorization" => "Bearer #{@token.token}" }

    assert_response :success
    message_ids = JSON.parse(response.body).fetch("messages").map { |message| message["id"] }

    assert_includes message_ids, pending_visible.id
    assert_includes message_ids, messages(:chat1_developer).id
    refute_includes message_ids, pending_empty.id
    refute_includes message_ids, failed_owner.id
  end

  test "show excludes pending assistant owners containing only unicode whitespace" do
    owners = [ "\n", "\t", " \t\r\n ", "\u00A0", "\u3000" ].map do |content|
      @chat.messages.create!(
        type: "AssistantMessage", content: content, ai_model: "openai/gpt-4o", status: :pending
      )
    end

    get "/api/v1/chats/#{@chat.id}", headers: { "Authorization" => "Bearer #{@token.token}" }

    assert_response :success
    message_ids = JSON.parse(response.body).fetch("messages").map { |message| message["id"] }
    owners.each { |owner| refute_includes message_ids, owner.id }
  end
end
