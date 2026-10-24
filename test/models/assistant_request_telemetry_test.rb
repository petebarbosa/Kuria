require "test_helper"

# End-to-end wiring for the Assistant's single terminal request event. The
# provider is a real Provider::RubyLlm whose chat_response is stubbed at the
# adapter seam so the Assistant's RubyLLM-only callback branches are used
# without any live model request.
class AssistantRequestTelemetryTest < ActiveSupport::TestCase
  include ProviderTestHelper

  MODEL = "openai/gpt-4o"
  COMPLETED_ID = "msg_telemetry_completed"
  ERROR_SECRET = "sk-provider-error-message-marker"

  setup do
    @chat = chats(:two)
    @message = @chat.messages.create!(
      type: "UserMessage",
      content: "What is my net worth?",
      ai_model: MODEL
    )
    @assistant = Assistant.for_chat(@chat)
    @provider = Provider::RubyLlm.new

    @assistant.stubs(:get_model_provider).returns(@provider)
  end

  test "emits one terminal success event with provider facts, tool outcomes, and wall latency" do
    @assistant.stubs(:monotonic_time).returns(100.0, 100.125)

    stub_chat_response(provider_event: provider_event) do |audit|
      audit.call(
        type: :tool_calls, round: 1,
        calls: [
          call(identity: "1:0", provider_call_id: "call_1"),
          call(identity: "1:1", provider_call_id: "call_2")
        ],
        status: :pending
      )
      audit.call(type: :tool_result, round: 1, identity: "1:0", result: '{"accounts":[]}')
      audit.call(type: :tool_result, round: 1, identity: "1:1", result: '{"error":"Invalid tool arguments."}')
      audit.call(
        type: :tool_calls, round: 2,
        calls: [ call(identity: "2:0", provider_call_id: "call_3") ],
        status: :not_executed,
        error: "Tool call was not executed because the response exceeded the tool-call limit."
      )
    end

    payloads, log = capture_telemetry { @assistant.respond_to(@message) }

    assert_equal 1, payloads.size
    event = payloads.first

    assert_equal "assistant.request.kuria", event[:event]
    assert_equal @message.id.to_s, event[:message_id]
    assert_equal @chat.id.to_s, event[:chat_id]
    assert_equal "openai", event[:provider]
    assert_equal MODEL, event[:model]
    assert_equal :success, event[:outcome]
    assert_equal 125, event[:latency_ms]
    assert_equal 0, event[:retry_count]
    assert_equal(
      { input_tokens: 10, output_tokens: 5, cache_read_tokens: nil, cache_write_tokens: nil, reasoning_tokens: nil },
      event[:usage]
    )
    assert_equal(
      { usd: 0.0001, known: true, source: Provider::RubyLlm::Pricing::SOURCE, reason: nil },
      event[:estimated_cost]
    )
    assert_equal({ succeeded: 1, rejected: 1, failed: 1 }, event[:tool_outcomes])
    assert_nil event[:error_class]
    assert_nil event[:error_retryable]

    assert_equal JSON.parse(event.to_json), JSON.parse(log)

    persisted = @chat.messages.ordered.where(type: "AssistantMessage").sole
    assert_equal "Done.", persisted.content
    assert_equal "complete", persisted.status
  end

  test "emits one terminal error event and counts interrupted tool execution as failed" do
    @assistant.stubs(:monotonic_time).returns(200.0, 200.25)

    error = Provider::RubyLlm::Error.new(
      ERROR_SECRET,
      details: { error_class: "RubyLLM::RateLimitError", retryable: true }
    )

    stub_chat_response(
      provider_event: provider_event(outcome: :error, error_class: "RubyLLM::RateLimitError", error_retryable: true),
      response: provider_error_response(error)
    ) do |audit|
      audit.call(
        type: :tool_calls, round: 1,
        calls: [ call(identity: "1:0", provider_call_id: "call_error") ],
        status: :pending
      )
    end

    payloads, log = capture_telemetry { @assistant.respond_to(@message) }

    assert_equal 1, payloads.size
    event = payloads.first

    assert_equal :error, event[:outcome]
    assert_equal "openai", event[:provider]
    assert_equal MODEL, event[:model]
    assert_equal 250, event[:latency_ms]
    assert_equal "RubyLLM::RateLimitError", event[:error_class]
    assert_equal true, event[:error_retryable]
    assert_equal({ succeeded: 0, rejected: 0, failed: 1 }, event[:tool_outcomes])

    assert_includes @chat.reload.error.to_s, ERROR_SECRET
    refute_includes event.to_json, ERROR_SECRET
    refute_includes log, ERROR_SECRET
  end

  test "counts a successful provider turn's never-dispatched pending call as rejected" do
    @assistant.stubs(:monotonic_time).returns(300.0, 300.05)

    stub_chat_response(provider_event: provider_event) do |audit|
      audit.call(
        type: :tool_calls, round: 1,
        calls: [ call(identity: "1:0", provider_call_id: "call_pending") ],
        status: :pending
      )
    end

    payloads, = capture_telemetry { @assistant.respond_to(@message) }

    assert_equal 1, payloads.size
    assert_equal({ succeeded: 0, rejected: 1, failed: 0 }, payloads.first[:tool_outcomes])
  end

  test "a telemetry service failure never changes a successful Assistant response" do
    AssistantTelemetry.stubs(:record).raises(StandardError, "sk-telemetry-internal-marker")

    stub_chat_response(provider_event: provider_event)

    assert_nothing_raised { @assistant.respond_to(@message) }

    persisted = @chat.messages.ordered.where(type: "AssistantMessage").sole
    assert_equal "Done.", persisted.content
    assert_equal "complete", persisted.status
  end

  private
    def stub_chat_response(provider_event:, response: nil)
      completed = completed_response
      response ||= provider_success_response(completed)

      @provider.stubs(:chat_response).with do |_prompt, **options|
        options[:telemetry_callback].call(provider_event)
        yield options[:audit_callback] if block_given?
        true
      end.returns(response)
    end

    def completed_response
      Provider::LlmConcept::ChatResponse.new(
        id: COMPLETED_ID,
        model: MODEL,
        messages: [
          Provider::LlmConcept::ChatMessage.new(id: COMPLETED_ID, output_text: "Done.")
        ],
        function_requests: []
      )
    end

    def provider_event(outcome: :success, error_class: nil, error_retryable: nil)
      {
        event: :ruby_llm_request,
        outcome: outcome,
        provider: "openai",
        model: MODEL,
        latency_ms: 12,
        retry_count: 0,
        usage: { input_tokens: 10, output_tokens: 5 },
        estimated_cost: {
          usd: 0.0001,
          known: true,
          source: Provider::RubyLlm::Pricing::SOURCE,
          reason: nil
        },
        error_class: error_class,
        error_retryable: error_retryable
      }
    end

    def call(identity:, provider_call_id:)
      {
        identity: identity,
        provider_call_id: provider_call_id,
        function_name: "get_accounts",
        arguments: {}
      }
    end

    def capture_telemetry
      payloads = []

      log = capture_log do
        ActiveSupport::Notifications.subscribed(
          ->(_name, _start, _finish, _id, payload) { payloads << payload },
          AssistantTelemetry::EVENT_NAME
        ) { yield }
      end

      [ payloads, log ]
    end

    def capture_log
      io = StringIO.new
      logger = Logger.new(io)
      logger.formatter = proc { |_severity, _time, _progname, message| "#{message}\n" }
      previous = Rails.logger

      Rails.logger = logger
      yield
      io.string
    ensure
      Rails.logger = previous
    end
end
