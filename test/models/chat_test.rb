require "test_helper"

class ChatTest < ActiveSupport::TestCase
  include ProviderTestHelper

  # Issue #16 seams: provider fakes at the Provider boundary so the real
  # Assistant/Chat/Message state machine is exercised without any network or
  # RubyLLM internals.
  class StreamFailureProvider
    def initialize(error, chunks: [])
      @error = error
      @chunks = chunks
    end

    def chat_response(_prompt, streamer:, **)
      @chunks.each do |text|
        streamer.call(Provider::LlmConcept::ChatStreamChunk.new(type: "output_text", data: text))
      end
      raise @error
    end
  end

  class StreamSuccessProvider
    def initialize(completed, chunks: [])
      @completed = completed
      @chunks = chunks
    end

    def chat_response(_prompt, streamer:, **)
      @chunks.each do |text|
        streamer.call(Provider::LlmConcept::ChatStreamChunk.new(type: "output_text", data: text))
      end
      Provider::Response.new(success?: true, data: @completed, error: nil)
    end
  end

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

  # --- Partial-stream recovery (issue #16) -------------------------------
  test "a mid-stream failure discards the partial assistant message so the retry re-runs the user's message" do
    chat = chats(:two)
    user_message = chat.messages.create!(type: "UserMessage", content: "Explain my budget", ai_model: "openai/gpt-4o")

    failure_provider = StreamFailureProvider.new(
      RubyLLM::ServerError.new("provider exploded mid-stream"),
      chunks: [ "Partial ", "answer" ]
    )
    success_provider = StreamSuccessProvider.new(
      Provider::LlmConcept::ChatResponse.new(
        id: "msg_retry_ok",
        model: "openai/gpt-4o",
        messages: [ Provider::LlmConcept::ChatMessage.new(id: "msg_retry_ok", output_text: "Full retry answer") ],
        function_requests: []
      ),
      chunks: [ "Full retry answer" ]
    )

    assistant = chat.assistant
    # First attempt fails mid-stream, the retried attempt succeeds.
    assistant.stubs(:get_model_provider).with("openai/gpt-4o").returns(failure_provider, success_provider)

    chat.ask_assistant(user_message)

    chat.reload
    assert chat.error.present?, "the chat must record the provider failure"
    # RED (issue #16): the partial streamed message must not survive the
    # failure and ghost the turn on reload.
    assert_equal 0, chat.messages.where(type: "AssistantMessage").count,
      "a failed streaming attempt must not leave a partial assistant message"
    assert_predicate chat, :needs_assistant_response?,
      "the retry gate must treat the chat as unanswered after the failed attempt"

    # Retrying neither duplicates the user's message nor creates a phantom
    # assistant turn before the response job runs. The queue adapter is the
    # test adapter, so the enqueued payload is inspected directly: the retry
    # must re-enqueue exactly this message (not a copy of it).
    assert_no_difference -> { chat.messages.where(type: "UserMessage").count } do
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear
      chat.retry_last_message!
    end

    enqueued = ActiveJob::Base.queue_adapter.enqueued_jobs
    assert_equal 1, enqueued.size
    assert_equal "AssistantResponseJob", enqueued.first["job_class"]
    assert_includes enqueued.first["arguments"].to_json, user_message.to_global_id.to_s

    # The retried attempt completes: exactly one assistant message, the chat's
    # error envelope is cleared, and the response id is recorded.
    AssistantResponseJob.perform_now(user_message)

    reloaded = Chat.find(chat.id)
    assert_equal [ "Full retry answer" ], reloaded.messages.where(type: "AssistantMessage").map(&:content)
    assert_equal "msg_retry_ok", reloaded.latest_assistant_response_id
    assert_nil reloaded.error, "the successful retry must clear the error envelope"
    assert_not_predicate reloaded, :needs_assistant_response?
    assert_equal 1, reloaded.messages.where(type: "AssistantMessage").count,
      "the retry must produce exactly one assistant answer, without duplicates"
  end
end
