require "test_helper"

class AssistantTelemetryTest < ActiveSupport::TestCase
  EVENT_NAME = "assistant.request.kuria"

  MESSAGE_ID = 123_456
  CHAT_ID = "0b631e3a-088a-52b3-a227-d61eba1c12fd"
  MODEL = "openai/gpt-5-nano"

  ALLOWED_EVENT_KEYS = %i[
    chat_id error_class error_retryable estimated_cost event latency_ms
    message_id model outcome provider retry_count tool_outcomes usage
  ].sort.freeze
  ALLOWED_USAGE_KEYS = %i[cache_read_tokens cache_write_tokens input_tokens output_tokens reasoning_tokens].freeze
  ALLOWED_COST_KEYS = %i[known reason source usd].freeze
  ALLOWED_TOOL_OUTCOME_KEYS = %i[failed rejected succeeded].freeze

  test "emits one strict request event to notifications and a structured info log" do
    provider_event = {
      event: :ruby_llm_request,
      outcome: :success,
      provider: "openai",
      model: MODEL,
      latency_ms: 42,
      retry_count: 0,
      usage: {
        input_tokens: 60,
        output_tokens: 20,
        cache_read_tokens: 40,
        cache_write_tokens: 0,
        reasoning_tokens: nil
      },
      estimated_cost: {
        usd: 0.0000112,
        known: true,
        source: Provider::RubyLlm::Pricing::SOURCE,
        reason: nil
      },
      error_class: nil,
      error_retryable: nil
    }

    payloads = []
    event = nil

    log = capture_log do
      ActiveSupport::Notifications.subscribed(notification_callback(payloads), EVENT_NAME) do
        event = AssistantTelemetry.record(
          message_id: MESSAGE_ID,
          chat_id: CHAT_ID,
          provider_event: provider_event,
          tool_outcomes: { succeeded: 1, rejected: 0, failed: 2 }
        )
      end
    end

    assert event.frozen?
    assert_equal ALLOWED_EVENT_KEYS, event.keys.sort
    assert_equal EVENT_NAME, event[:event]
    assert_equal MESSAGE_ID.to_s, event[:message_id]
    assert_equal CHAT_ID, event[:chat_id]
    assert_equal "openai", event[:provider]
    assert_equal MODEL, event[:model]
    assert_equal :success, event[:outcome]
    assert_equal 42, event[:latency_ms]
    assert_equal 0, event[:retry_count]
    assert_equal provider_event[:usage], event[:usage]
    assert_equal ALLOWED_USAGE_KEYS.sort, event[:usage].keys.sort
    assert event[:usage].frozen?
    assert_equal provider_event[:estimated_cost], event[:estimated_cost]
    assert_equal ALLOWED_COST_KEYS.sort, event[:estimated_cost].keys.sort
    assert event[:estimated_cost].frozen?
    assert_equal({ succeeded: 1, rejected: 0, failed: 2 }, event[:tool_outcomes])
    assert_equal ALLOWED_TOOL_OUTCOME_KEYS.sort, event[:tool_outcomes].keys.sort
    assert event[:tool_outcomes].frozen?
    assert_nil event[:error_class]
    assert_nil event[:error_retryable]

    assert_equal [ event ], payloads
    assert_equal JSON.parse(event.to_json), JSON.parse(log)
  end

  test "rebuilds nested fields and validates every identity string instead of forwarding arbitrary payloads" do
    provider_event = {
      event: :ruby_llm_request,
      outcome: :success,
      provider: "sk-provider-secret-marker",
      model: "openai/sk-model-secret-marker",
      latency_ms: "sk-latency-secret-marker",
      retry_count: -1,
      usage: {
        input_tokens: "sk-usage-secret-marker",
        output_tokens: 1.5,
        cache_read_tokens: -2,
        cache_write_tokens: 3,
        reasoning_tokens: 4,
        prompt: "sk-nested-prompt-secret-marker",
        nested: { api_key: "sk-nested-key-secret-marker" }
      },
      estimated_cost: {
        usd: 0,
        known: false,
        source: "sk-source-secret-marker",
        reason: "sk-reason-secret-marker",
        nested: { authorization: "sk-nested-auth-secret-marker" }
      },
      error_class: "Secret Class / sk-error-secret-marker",
      error_retryable: "true",
      prompt: "sk-top-level-prompt-secret-marker",
      tool_results: [ { content: "sk-tool-secret-marker" } ]
    }

    payloads = []
    event = nil

    log = capture_log do
      ActiveSupport::Notifications.subscribed(notification_callback(payloads), EVENT_NAME) do
        event = AssistantTelemetry.record(
          message_id: "sk-message-id-secret-marker",
          chat_id: "chat id with spaces and sk-chat-id-secret-marker",
          provider_event: provider_event,
          tool_outcomes: {
            succeeded: 2,
            rejected: "sk-tool-count-secret-marker",
            failed: 1.5,
            secret: "sk-tool-key-secret-marker"
          }
        )
      end
    end

    assert_equal [ event ], payloads
    assert_nil event[:message_id]
    assert_nil event[:chat_id]
    assert_nil event[:provider]
    assert_nil event[:model]
    assert_equal :success, event[:outcome]
    assert_nil event[:latency_ms]
    assert_nil event[:retry_count]
    assert_equal(
      { input_tokens: nil, output_tokens: nil, cache_read_tokens: nil, cache_write_tokens: 3, reasoning_tokens: 4 },
      event[:usage]
    )
    assert_equal({ succeeded: 2, rejected: 0, failed: 0 }, event[:tool_outcomes])
    assert_equal({ usd: nil, known: false, source: nil, reason: nil }, event[:estimated_cost])
    assert_nil event[:error_class]
    assert_nil event[:error_retryable]

    [ event.to_json, log ].each do |payload|
      secret_markers.each { |marker| refute_includes payload, marker }
      refute_includes payload, "prompt"
      refute_includes payload, "tool_results"
      refute_includes payload, "nested"
      refute_includes payload, "api_key"
      refute_includes payload, "authorization"
    end
  end

  test "derives canonical provider from an admitted model and allows explicit outcome overrides" do
    event = AssistantTelemetry.record(
      message_id: MESSAGE_ID,
      chat_id: CHAT_ID,
      provider_event: {
        outcome: :success,
        provider: "opencode_go",
        model: MODEL,
        latency_ms: 5
      },
      outcome: :error,
      latency_ms: 99
    )

    assert_equal "openai", event[:provider]
    assert_equal MODEL, event[:model]
    assert_equal :error, event[:outcome]
    assert_equal 99, event[:latency_ms]
  end

  test "unknown pricing remains nil even when a provider payload supplies a numeric zero" do
    event = AssistantTelemetry.record(
      message_id: MESSAGE_ID,
      chat_id: CHAT_ID,
      provider_event: {
        outcome: :success,
        provider: "opencode_go",
        model: "opencode_go/deepseek-v4.1-flash",
        estimated_cost: {
          usd: 0,
          known: false,
          source: nil,
          reason: Provider::RubyLlm::Pricing::UNKNOWN_PRICING_REASON
        }
      }
    )

    assert_equal "opencode_go", event[:provider]
    assert_equal({ usd: nil, known: false, source: nil, reason: "no_authoritative_pricing_source" },
      event[:estimated_cost])
  end

  test "a known cost without an allowlisted source is downgraded to unknown" do
    event = AssistantTelemetry.record(
      provider_event: {
        outcome: :success,
        provider: "openai",
        model: MODEL,
        estimated_cost: { usd: 1.25, known: true, source: "sk-untrusted-source", reason: nil }
      }
    )

    assert_equal({ usd: nil, known: false, source: nil, reason: nil }, event[:estimated_cost])
  end

  test "sanitizes error identity and retryability for error outcomes" do
    event = AssistantTelemetry.record(
      provider_event: {
        outcome: :error,
        provider: "openai",
        model: MODEL,
        error_class: "RubyLLM::UnauthorizedError",
        error_retryable: false
      }
    )

    assert_equal :error, event[:outcome]
    assert_equal "RubyLLM::UnauthorizedError", event[:error_class]
    assert_equal false, event[:error_retryable]

    unsafe = AssistantTelemetry.record(
      provider_event: {
        outcome: :error,
        error_class: "sk-error-class-secret-marker",
        error_retryable: "true"
      }
    )

    assert_nil unsafe[:error_class]
    assert_nil unsafe[:error_retryable]
  end

  test "notification failures are swallowed and do not prevent the structured log or return value" do
    ActiveSupport::Notifications.stubs(:instrument).raises(RuntimeError, "sk-notification-failure-marker")

    event = nil
    log = capture_log do
      event = AssistantTelemetry.record(
        message_id: MESSAGE_ID,
        chat_id: CHAT_ID,
        provider_event: provider_event(outcome: :success)
      )
    end

    assert event.present?
    refute_includes log, "sk-notification-failure-marker"
    assert_equal JSON.parse(event.to_json), JSON.parse(log)
  end

  test "logging failures are swallowed and do not prevent the notification or return value" do
    raising_logger = Object.new
    raising_logger.define_singleton_method(:info) { |_message| raise "sk-logging-failure-marker" }
    Rails.stubs(:logger).returns(raising_logger)

    payloads = []
    event = nil

    ActiveSupport::Notifications.subscribed(notification_callback(payloads), EVENT_NAME) do
      event = AssistantTelemetry.record(
        message_id: MESSAGE_ID,
        chat_id: CHAT_ID,
        provider_event: provider_event(outcome: :success)
      )
    end

    assert event.present?
    assert_equal [ event ], payloads
  end

  test "notification and logging failures together still return the sanitized event" do
    ActiveSupport::Notifications.stubs(:instrument).raises(RuntimeError, "sk-notification-failure-marker")
    raising_logger = Object.new
    raising_logger.define_singleton_method(:info) { |_message| raise "sk-logging-failure-marker" }
    Rails.stubs(:logger).returns(raising_logger)

    event = AssistantTelemetry.record(
      message_id: MESSAGE_ID,
      chat_id: CHAT_ID,
      provider_event: provider_event(outcome: :success)
    )

    assert event.present?
    assert_equal EVENT_NAME, event[:event]
  end

  private
    def provider_event(outcome:)
      {
        event: :ruby_llm_request,
        outcome: outcome,
        provider: "openai",
        model: MODEL,
        latency_ms: 7,
        retry_count: 0,
        usage: { input_tokens: 1, output_tokens: 1 },
        estimated_cost: {
          usd: 0.000001,
          known: true,
          source: Provider::RubyLlm::Pricing::SOURCE,
          reason: nil
        }
      }
    end

    def notification_callback(payloads)
      ->(_name, _start, _finish, _id, payload) { payloads << payload }
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

    def secret_markers
      %w[
        sk-provider-secret-marker sk-model-secret-marker sk-latency-secret-marker
        sk-usage-secret-marker sk-nested-prompt-secret-marker sk-nested-key-secret-marker
        sk-source-secret-marker sk-reason-secret-marker sk-nested-auth-secret-marker
        sk-error-secret-marker sk-top-level-prompt-secret-marker sk-tool-secret-marker
        sk-message-id-secret-marker sk-chat-id-secret-marker sk-tool-count-secret-marker
        sk-tool-key-secret-marker
      ]
    end
end
