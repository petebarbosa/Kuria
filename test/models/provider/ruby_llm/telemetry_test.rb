require "test_helper"

# Drives a real RubyLLM 2.1.1 streaming request through the adapter boundary
# (WebMock, no live provider) and asserts the telemetry contract: one frozen,
# strictly allowlisted event per request, with privacy-sensitive data absent.
class Provider::RubyLlm::TelemetryTest < ActiveSupport::TestCase
  MODELS_URL = "https://api.openai.com/v1/models"
  CHAT_URL = "https://api.openai.com/v1/chat/completions"
  CREDENTIAL = "sk-test-telemetry-credential-marker"
  PROMPT = "PROMPT-MARKER checking balance 123456.78"
  COMPLETION = "COMPLETION-MARKER total assets 987654.32"
  PROVIDER_ERROR = "SECRET-PROVIDER-BODY-MARKER"
  CALLBACK_ERROR = "SECRET-CALLBACK-MARKER"
  MODEL = "openai/gpt-5-nano"

  class TelemetryEchoTool < RubyLLM::Tool
    def self.tool_name
      "telemetry_echo"
    end

    description "Echo a fixed result."

    def execute(**_arguments)
      { "echo" => true }
    end
  end

  ALLOWED_EVENT_KEYS = %i[
    estimated_cost error_class error_retryable event latency_ms model outcome
    provider retry_count usage
  ].sort.freeze

  EXPECTED_USAGE = {
    input_tokens: 60,
    output_tokens: 20,
    cache_read_tokens: 40,
    cache_write_tokens: 0,
    reasoning_tokens: nil
  }.freeze

  test "emits one allowlisted success event with final usage and explicit cost source" do
    stub_live_models
    stub_stream(success_body)

    events = []
    chunks = []

    response = with_openai_key do
      Provider::RubyLlm.new.chat_response(
        PROMPT,
        model: MODEL,
        streamer: ->(chunk) { chunks << chunk },
        telemetry_callback: ->(event) { events << event }
      )
    end

    assert response.success?
    assert_equal COMPLETION, response.data.messages.first.output_text
    assert_equal 1, events.size

    event = events.first
    assert event.frozen?, "the telemetry event must be immutable"
    assert_equal ALLOWED_EVENT_KEYS, event.keys.sort
    assert_equal :ruby_llm_request, event[:event]
    assert_equal :success, event[:outcome]
    assert_equal "openai", event[:provider]
    assert_equal MODEL, event[:model]
    assert_kind_of Integer, event[:latency_ms]
    assert_operator event[:latency_ms], :>=, 0
    assert_equal 0, event[:retry_count]
    assert_equal EXPECTED_USAGE, event[:usage]
    assert event[:usage].frozen?
    assert_equal %i[cache_read_tokens cache_write_tokens input_tokens output_tokens reasoning_tokens], event[:usage].keys.sort
    assert_nil event[:error_class]
    assert_nil event[:error_retryable]

    cost = event[:estimated_cost]
    assert_equal %i[known reason source usd], cost.keys.sort
    assert cost[:known]
    assert_equal Provider::RubyLlm::Pricing::SOURCE, cost[:source]
    assert_nil cost[:reason]
    assert_in_delta 0.0000112, cost[:usd], 1e-12

    assert_equal COMPLETION, chunks.find { |chunk| chunk.type == "output_text" }.data
    assert_same response.data, chunks.last.data
    assert_no_private_markers(event)
  end

  test "aggregates usage and cost across tool rounds and keeps retry_count at zero" do
    stub_live_models
    stub_round_streams(tool_call_body, final_round_body)

    events = []

    response = with_openai_key do
      Provider::RubyLlm.new.chat_response(
        PROMPT,
        model: MODEL,
        streamer: proc { },
        tool: [ TelemetryEchoTool ],
        telemetry_callback: ->(event) { events << event }
      )
    end

    assert response.success?
    assert_equal COMPLETION, response.data.messages.first.output_text
    assert_equal 1, events.size

    event = events.first
    assert_equal :success, event[:outcome]
    assert_equal 0, event[:retry_count], "tool rounds are not retries"
    assert_equal(
      {
        input_tokens: 210,
        output_tokens: 50,
        cache_read_tokens: 90,
        cache_write_tokens: 0,
        reasoning_tokens: nil
      },
      event[:usage]
    )
    assert event[:estimated_cost][:known]
    assert_in_delta 0.00003095, event[:estimated_cost][:usd], 1e-12
    assert_requested :post, CHAT_URL, times: 2
  end

  test "retains earlier-round usage when a later tool round fails and keeps cost unknown" do
    stub_live_models
    stub_round_streams(tool_call_body, status: 500)

    events = []

    response = with_openai_key do
      Provider::RubyLlm.new.chat_response(
        PROMPT,
        model: MODEL,
        streamer: proc { },
        tool: [ TelemetryEchoTool ],
        telemetry_callback: ->(event) { events << event }
      )
    end

    refute response.success?
    assert_equal "RubyLLM::ServerError", response.error.details[:error_class]
    assert_equal 1, events.size

    event = events.first
    assert_equal :error, event[:outcome]
    assert_equal 0, event[:retry_count], "tool rounds are not retries"
    assert_equal(
      {
        input_tokens: 60,
        output_tokens: 20,
        cache_read_tokens: 40,
        cache_write_tokens: 0,
        reasoning_tokens: nil
      },
      event[:usage]
    )
    refute event[:estimated_cost][:known]
    assert_nil event[:estimated_cost][:usd]
    assert_equal "usage_unavailable", event[:estimated_cost][:reason]
    assert_requested :post, CHAT_URL, times: 2
  end

  test "emits an error event without provider content and preserves the failure response" do
    stub_live_models
    stub_request(:post, CHAT_URL)
      .with(headers: { "Authorization" => "Bearer #{CREDENTIAL}" })
      .to_return(
        status: 401,
        headers: { "Content-Type" => "application/json" },
        body: { "error" => { "message" => PROVIDER_ERROR } }.to_json
      )

    events = []

    response = with_openai_key do
      Provider::RubyLlm.new.chat_response(
        PROMPT,
        model: MODEL,
        streamer: proc { },
        telemetry_callback: ->(event) { events << event }
      )
    end

    refute response.success?
    assert_equal "RubyLLM::UnauthorizedError", response.error.details[:error_class]
    refute_match(/#{PROVIDER_ERROR}/, response.error.message)

    assert_equal 1, events.size
    event = events.first
    assert_equal ALLOWED_EVENT_KEYS, event.keys.sort
    assert_equal :error, event[:outcome]
    assert_equal "openai", event[:provider]
    assert_equal MODEL, event[:model]
    assert_kind_of Integer, event[:latency_ms]
    assert_equal 0, event[:retry_count]
    # RubyLLM records a refused 401 attempt as a reported zero-token attempt.
    assert_equal(
      {
        input_tokens: 0,
        output_tokens: 0,
        cache_read_tokens: nil,
        cache_write_tokens: nil,
        reasoning_tokens: nil
      },
      event[:usage]
    )
    assert_equal "RubyLLM::UnauthorizedError", event[:error_class]
    assert_equal false, event[:error_retryable]

    cost = event[:estimated_cost]
    assert cost[:known]
    assert_equal 0.0, cost[:usd]
    assert_equal Provider::RubyLlm::Pricing::SOURCE, cost[:source]
    assert_nil cost[:reason]

    assert_no_private_markers(event)
  end

  test "retriable streaming failures are not retried, so retry_count is the real zero" do
    stub_live_models
    stub_request(:post, CHAT_URL)
      .with(headers: { "Authorization" => "Bearer #{CREDENTIAL}" })
      .to_return(
        status: 500,
        headers: { "Content-Type" => "application/json" },
        body: { "error" => { "message" => PROVIDER_ERROR } }.to_json
      )

    events = []

    response = with_openai_key do
      Provider::RubyLlm.new.chat_response(
        PROMPT,
        model: MODEL,
        streamer: proc { },
        telemetry_callback: ->(event) { events << event }
      )
    end

    refute response.success?
    assert_equal "RubyLLM::ServerError", response.error.details[:error_class]
    assert_equal true, response.error.details[:retryable]
    assert_equal 0, events.first[:retry_count]
    assert_requested :post, CHAT_URL, times: 1
  end

  test "a raising callback cannot change a successful response or streaming output" do
    stub_live_models
    stub_stream(success_body)

    chunks = []
    callback = ->(_event) { raise CALLBACK_ERROR }

    response = with_openai_key do
      Provider::RubyLlm.new.chat_response(
        PROMPT,
        model: MODEL,
        streamer: ->(chunk) { chunks << chunk },
        telemetry_callback: callback
      )
    end

    assert response.success?
    assert_equal COMPLETION, response.data.messages.first.output_text
    assert_equal COMPLETION, chunks.find { |chunk| chunk.type == "output_text" }.data
    assert_same response.data, chunks.last.data
  end

  test "a raising callback cannot hide or alter a provider error" do
    stub_live_models
    stub_request(:post, CHAT_URL)
      .with(headers: { "Authorization" => "Bearer #{CREDENTIAL}" })
      .to_return(
        status: 401,
        headers: { "Content-Type" => "application/json" },
        body: { "error" => { "message" => PROVIDER_ERROR } }.to_json
      )

    response = with_openai_key do
      Provider::RubyLlm.new.chat_response(
        PROMPT,
        model: MODEL,
        streamer: proc { },
        telemetry_callback: ->(_event) { raise CALLBACK_ERROR }
      )
    end

    refute response.success?
    assert_equal "RubyLLM::UnauthorizedError", response.error.details[:error_class]
    refute_match(/#{CALLBACK_ERROR}/, response.error.message)
    refute_match(/#{PROVIDER_ERROR}/, response.error.message)
  end

  test "Go telemetry reports the logical account and leaves pricing explicitly unknown" do
    models_url = "https://opencode.ai/zen/go/v1/models"
    chat_url = "https://opencode.ai/zen/go/v1/chat/completions"
    credential = "sk-test-go-telemetry-key"
    reference = "opencode_go/deepseek-v4.1-flash"

    stub_request(:get, models_url)
      .with(headers: { "Accept" => "application/json", "Authorization" => "Bearer #{credential}" })
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { object: "list", data: [ { id: "deepseek-v4.1-flash", object: "model" } ] }.to_json
      )
    stub_request(:post, chat_url)
      .with(headers: { "Authorization" => "Bearer #{credential}" })
      .to_return(
        status: 200,
        headers: { "Content-Type" => "text/event-stream" },
        body: success_body(model: "deepseek-v4.1-flash")
      )

    events = []

    response = with_env("OPENCODE_GO_API_KEY" => credential, "OPENAI_API_KEY" => nil) do
      Provider::RubyLlm.new.chat_response(
        PROMPT,
        model: reference,
        streamer: proc { },
        telemetry_callback: ->(event) { events << event }
      )
    end

    assert response.success?
    event = events.first
    assert_equal "opencode_go", event[:provider]
    assert_equal reference, event[:model]
    refute event[:estimated_cost][:known]
    assert_nil event[:estimated_cost][:usd]
    assert_nil event[:estimated_cost][:source]
    assert_equal "no_authoritative_pricing_source", event[:estimated_cost][:reason]
    assert_no_private_markers(event)
  end

  private

    def with_openai_key(&block)
      with_env("OPENAI_API_KEY" => CREDENTIAL, &block)
    end

    def with_env(overrides)
      previous = overrides.keys.to_h { |key| [ key, ENV[key] ] }
      overrides.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      yield
    ensure
      previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end

    def stub_live_models
      stub_request(:get, MODELS_URL)
        .with(headers: { "Accept" => "application/json", "Authorization" => "Bearer #{CREDENTIAL}" })
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { object: "list", data: [ { id: "gpt-5-nano", object: "model" } ] }.to_json
        )
    end

    def stub_stream(body)
      stub_request(:post, CHAT_URL)
        .with(headers: { "Authorization" => "Bearer #{CREDENTIAL}" })
        .to_return(status: 200, headers: { "Content-Type" => "text/event-stream" }, body: body)
    end

    def stub_round_streams(tool_round_body, final_body = nil, status: 200)
      responses = [
        { status: 200, headers: { "Content-Type" => "text/event-stream" }, body: tool_round_body }
      ]

      responses << if final_body
        { status: 200, headers: { "Content-Type" => "text/event-stream" }, body: final_body }
      else
        {
          status: status,
          headers: { "Content-Type" => "application/json" },
          body: { "error" => { "message" => PROVIDER_ERROR } }.to_json
        }
      end

      stub_request(:post, CHAT_URL)
        .with(headers: { "Authorization" => "Bearer #{CREDENTIAL}" })
        .to_return(*responses)
    end

    def tool_call_body
      [
        sse_event(
          id: "chatcmpl-telemetry-round-1", object: "chat.completion.chunk", model: "gpt-5-nano",
          choices: [ {
            index: 0,
            delta: {
              role: "assistant",
              tool_calls: [ {
                index: 0,
                id: "call_echo",
                type: "function",
                function: { name: "telemetry_echo", arguments: "{}" }
              } ]
            },
            finish_reason: nil
          } ]
        ),
        usage_event(prompt_tokens: 100, completion_tokens: 20, total_tokens: 120, cached_tokens: 40),
        sse_event(
          id: "chatcmpl-telemetry-round-1", object: "chat.completion.chunk", model: "gpt-5-nano",
          choices: [ { index: 0, delta: {}, finish_reason: "tool_calls" } ]
        ),
        sse_event("[DONE]")
      ].join
    end

    def final_round_body
      [
        sse_event(
          id: "chatcmpl-telemetry-round-2", object: "chat.completion.chunk", model: "gpt-5-nano",
          choices: [ { index: 0, delta: { role: "assistant", content: COMPLETION }, finish_reason: nil } ]
        ),
        usage_event(prompt_tokens: 200, completion_tokens: 30, total_tokens: 230, cached_tokens: 50),
        sse_event(
          id: "chatcmpl-telemetry-round-2", object: "chat.completion.chunk", model: "gpt-5-nano",
          choices: [ { index: 0, delta: {}, finish_reason: "stop" } ]
        ),
        sse_event("[DONE]")
      ].join
    end

    def usage_event(prompt_tokens:, completion_tokens:, total_tokens:, cached_tokens:)
      sse_event(
        id: "chatcmpl-telemetry-usage", object: "chat.completion.chunk", model: "gpt-5-nano",
        choices: [],
        usage: {
          prompt_tokens: prompt_tokens,
          completion_tokens: completion_tokens,
          total_tokens: total_tokens,
          prompt_tokens_details: { cached_tokens: cached_tokens }
        }
      )
    end

    # OpenAI-shaped Chat Completions stream: content, final usage (with cache
    # read detail), stop, and the mandatory [DONE] sentinel.
    def success_body(model: "gpt-5-nano")
      [
        sse_event(
          id: "chatcmpl-telemetry", object: "chat.completion.chunk", model: model,
          choices: [ { index: 0, delta: { role: "assistant", content: COMPLETION }, finish_reason: nil } ]
        ),
        sse_event(
          id: "chatcmpl-telemetry", object: "chat.completion.chunk", model: model,
          choices: [],
          usage: {
            prompt_tokens: 100,
            completion_tokens: 20,
            total_tokens: 120,
            prompt_tokens_details: { cached_tokens: 40 }
          }
        ),
        sse_event(
          id: "chatcmpl-telemetry", object: "chat.completion.chunk", model: model,
          choices: [ { index: 0, delta: {}, finish_reason: "stop" } ]
        ),
        sse_event("[DONE]")
      ].join
    end

    def sse_event(payload)
      "data: #{payload.is_a?(String) ? payload : payload.to_json}\n\n"
    end

    def assert_no_private_markers(event)
      payload = event.to_json

      {
        "prompt" => PROMPT,
        "completion" => COMPLETION,
        "credential" => CREDENTIAL,
        "provider body" => PROVIDER_ERROR,
        "callback error" => CALLBACK_ERROR,
        "authorization" => "Authorization",
        "bearer token" => "Bearer"
      }.each do |label, marker|
        refute_includes payload, marker, "#{label} must not appear in telemetry"
      end
    end
end
