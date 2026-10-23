require "test_helper"

# RubyLLM's debug and stream-debug output carries prompts, request and
# response bodies, tool results and provider error text. Kuria's assistant
# traffic is financial, so the gem's global logger must emit only a fixed
# label and severity. These tests drive a real RubyLLM request through WebMock
# and assert no synthetic marker reaches the logger's output.
class Provider::RubyLlmLoggingTest < ActiveSupport::TestCase
  CREDENTIAL = "sk-test-logging-credential-marker"
  PROMPT = "PROMPT-MARKER checking balance 123456.78"
  COMPLETION = "COMPLETION-MARKER total assets 987654.32"
  TOOL_RESULT = "TOOL-MARKER account balance 987654.32"
  ERROR_MESSAGE = "ERROR-MARKER upstream provider exploded"

  CHAT_URL = "https://api.openai.com/v1/chat/completions"

  setup do
    @logger = RubyLLM.logger
    @original_level = @logger.level
    @original_formatter = @logger.formatter
    @original_logdev = @logger.instance_variable_get(:@logdev)
    @original_config_logger = RubyLLM.config.logger
    @original_stream_debug = RubyLLM.config.log_stream_debug

    @output = StringIO.new
    @logger.instance_variable_set(:@logdev, Logger::LogDevice.new(@output))
    @logger.level = Logger::DEBUG
  end

  teardown do
    @logger.level = @original_level
    @logger.formatter = @original_formatter
    @logger.instance_variable_set(:@logdev, @original_logdev)
    RubyLLM.config.logger = @original_config_logger
    RubyLLM.config.log_stream_debug = @original_stream_debug
  end

  test "the global logger never writes prompts, completions, credentials, tool results, or provider errors" do
    RubyLLM.config.log_stream_debug = true
    stub_request(:post, CHAT_URL)
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: completion_body)

    reply = context
      .chat(model: "gpt-4o", provider: :openai, protocol: :chat_completions, assume_model_exists: true)
      .ask(PROMPT)

    assert_equal COMPLETION, reply.content

    # The gem writes tool results and raw streaming chunks through the same
    # logger channel this formatter guards.
    RubyLLM.logger.debug { "Tool balance returned: #{TOOL_RESULT}" }
    RubyLLM.logger.debug { "Received chunk: #{COMPLETION}" }

    assert_no_markers
    lines = @output.string.lines
    refute_empty lines
    lines.each do |line|
      assert_match(/\A\[RubyLLM\] (DEBUG|INFO|WARN|ERROR|FATAL|ANY)\n\z/, line,
        "every line must be the fixed label and severity only")
    end
  end

  test "provider error bodies are never written to the global logger" do
    stub_request(:post, CHAT_URL)
      .to_return(
        status: 500,
        headers: { "Content-Type" => "application/json" },
        body: { "error" => { "message" => ERROR_MESSAGE } }.to_json
      )

    assert_raises(RubyLLM::Error) do
      context
        .chat(model: "gpt-4o", provider: :openai, protocol: :chat_completions, assume_model_exists: true)
        .ask(PROMPT)
    end

    assert_no_markers
  end

  test "a later config.logger assignment does not bypass the cached logger's sanitizer" do
    replacement_output = StringIO.new
    RubyLLM.config.logger = Logger.new(replacement_output)

    # The global logger was cached at boot; a caller's replacement does not
    # reroute the gem's logs around the installed formatter.
    assert_same @logger, RubyLLM.logger

    stub_request(:post, CHAT_URL)
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: completion_body)
    context
      .chat(model: "gpt-4o", provider: :openai, protocol: :chat_completions, assume_model_exists: true)
      .ask(PROMPT)

    assert_no_markers
    assert_empty replacement_output.string, "the replacement logger must not receive gem output"
  end

  private
    def context
      RubyLLM.context do |config|
        config.openai_api_key = CREDENTIAL
        config.openai_api_base = "https://api.openai.com/v1"
      end
    end

    def completion_body
      {
        id: "chatcmpl-logging", object: "chat.completion", model: "gpt-4o",
        choices: [ { index: 0, message: { role: "assistant", content: COMPLETION }, finish_reason: "stop" } ],
        usage: { prompt_tokens: 3, completion_tokens: 4, total_tokens: 7 }
      }.to_json
    end

    def assert_no_markers
      { "credential" => CREDENTIAL, "prompt" => PROMPT, "completion" => COMPLETION,
        "tool result" => TOOL_RESULT, "provider error" => ERROR_MESSAGE }.each do |label, marker|
        refute_includes @output.string, marker, "#{label} must not reach the logger"
      end
    end
end
