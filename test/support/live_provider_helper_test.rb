require "test_helper"
require "socket"

# Deterministic tests for the live compatibility harness (#19). Nothing in
# this file contacts a model provider: provider boundaries are stubbed with
# WebMock, and the live gate is exercised before any catalog or network work.
class LiveProviderHelperTest < ActiveSupport::TestCase
  FakeConfig = Struct.new(
    :openai_api_key, :openai_api_base, :openai_organization_id, :openai_project_id,
    :opencode_go_session_id, :faraday_adapter, :instrumenter, :request_timeout, :max_retries,
    :retry_interval, :retry_max_interval, :retry_backoff_factor, :retry_interval_randomness,
    keyword_init: true
  )

  class FakeChat
    def initialize(message)
      @message = message
    end

    def with_instructions(_instructions)
      self
    end

    def ask(_prompt)
      yield if block_given?
      @message
    end
  end

  class FakeContext
    attr_reader :options

    def initialize(chat)
      @chat = chat
    end

    def chat(**options)
      @options = options
      @chat
    end
  end

  FakeMessage = Struct.new(:content, :id)

  def header_value(headers, name)
    pair = headers.find { |key, _| key.to_s.casecmp?(name) }
    pair && pair[1]
  end

  def assert_config_value(expected, actual)
    expected.nil? ? assert_nil(actual) : assert_equal(expected, actual)
  end

  def stub_catalog_models(account, ids:, key:)
    url = if account == :openai
      Provider::RubyLlm::OPENAI_BASE_URL + "/models"
    else
      Provider::RubyLlm::OPENCODE_GO_MODELS_URL
    end

    stub_request(:get, url)
      .with(headers: { "Authorization" => "Bearer #{key}" })
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { object: "list", data: ids.map { |id| { "id" => id } } }.to_json
      )
  end

  # Serves one deterministic HTTP response from a second loopback address.
  # VCR ignores 127.0.0.1 but not 127.0.0.2, so this exercises the VCR hook
  # without any external network or DNS dependency.
  def with_synthetic_http_server
    server = TCPServer.new("127.0.0.2", 0)
    port = server.addr[1]

    server_thread = Thread.new do
      client = server.accept
      client.gets
      body = "{}"
      client.write(
        "HTTP/1.1 200 OK\r\n" \
        "Content-Type: application/json\r\n" \
        "Content-Length: #{body.bytesize}\r\n" \
        "Connection: close\r\n\r\n#{body}"
      )
    rescue IOError, Errno::ECONNRESET, Errno::EPIPE
      # The client may abort before reading (for example when VCR blocks it).
    ensure
      client&.close
    end

    yield "http://127.0.0.2:#{port}/synthetic"

    server_thread.join(5)
    flunk "synthetic server did not finish" if server_thread.alive?
  ensure
    server&.close
    server_thread&.kill if server_thread&.alive?
  end

  test "live gate is disabled without the explicit opt-in flag" do
    env = { LiveProviderHelper::LIVE_ENV => "0", "OPENAI_API_KEY" => "never-print-this-value" }

    gate = LiveProviderHelper.live_gate(provider: :openai, env:)

    refute gate.enabled?
    assert_match(/KURIA_LIVE_LLM_TESTS/, gate.reason)
    refute_includes gate.reason, "never-print-this-value"
  end

  test "live gate is disabled when the provider credential is absent" do
    gate = LiveProviderHelper.live_gate(
      provider: :openai,
      env: { LiveProviderHelper::LIVE_ENV => "1" }
    )

    refute gate.enabled?
    assert_match(/OPENAI_API_KEY/, gate.reason)
  end

  test "live gate is enabled only when the flag and credential are present" do
    gate = LiveProviderHelper.live_gate(
      provider: :openai,
      env: {
        LiveProviderHelper::LIVE_ENV => "1",
        "OPENAI_API_KEY" => "present"
      }
    )

    assert gate.enabled?
    assert_nil gate.reason
  end

  test "run_live never yields before the gate passes" do
    yielded = false

    gate = LiveProviderHelper.run_live(
      provider: :openai,
      env: { LiveProviderHelper::LIVE_ENV => "0" }
    ) { yielded = true }

    refute gate.enabled?
    refute yielded
  end

  test "model reference must be explicit and is never selected automatically" do
    env = {
      LiveProviderHelper::LIVE_ENV => "1",
      "OPENAI_API_KEY" => "present",
      LiveProviderHelper::OPENAI_MODEL_ENV => "openai/gpt-5-nano"
    }

    assert_equal(
      "openai/gpt-5-nano",
      LiveProviderHelper.live_model_reference!(:openai, env:)
    )

    error = assert_raises(LiveProviderHelper::MissingModelReferenceError) do
      LiveProviderHelper.live_model_reference!(
        :openai,
        env: env.except(LiveProviderHelper::OPENAI_MODEL_ENV)
      )
    end

    assert_match(/KURIA_LIVE_OPENAI_MODEL/, error.message)
    refute_match(/gpt-5-nano/, error.message)
  end

  test "known Responses-only and Anthropic Go references are rejected without downgrade" do
    cases = {
      "opencode_go/gpt-6-luna" => /Responses API/,
      "opencode_go/claude-haiku-5-5" => /Anthropic Messages API/,
      "opencode_go/gemini-4-argon-contributor" => /Gemini API/
    }

    cases.each do |reference, api_pattern|
      error = assert_raises(LiveProviderHelper::UnsupportedModelError) do
        LiveProviderHelper.validate_reference!(provider: :opencode_go, reference:)
      end

      assert_match api_pattern, error.message
      assert_match(/will not downgrade or substitute/, error.message)
    end
  end

  test "uncatalogued or wrong-provider references are rejected instead of substituted" do
    uncatalogued = assert_raises(LiveProviderHelper::UnsupportedModelError) do
      LiveProviderHelper.validate_reference!(provider: :openai, reference: "openai/does-not-exist")
    end

    assert_match(/not in Kuria's verified Chat Completions catalog/, uncatalogued.message)
    assert_match(/no model was substituted/, uncatalogued.message)

    wrong_provider = assert_raises(LiveProviderHelper::UnsupportedModelError) do
      LiveProviderHelper.validate_reference!(provider: :openai, reference: "anthropic/claude-3-5-sonnet")
    end

    assert_match(/Expected an explicit openai\//, wrong_provider.message)
    assert_match(/no model was substituted/, wrong_provider.message)
  end

  test "catalogued Chat Completions references are accepted as-is" do
    assert_equal(
      "openai/gpt-5-nano",
      LiveProviderHelper.validate_reference!(provider: :openai, reference: "openai/gpt-5-nano")
    )
    assert_equal(
      "opencode_go/glm-5.3-flash",
      LiveProviderHelper.validate_reference!(provider: :opencode_go, reference: "opencode_go/glm-5.3-flash")
    )
  end

  test "missing credential fails closed before any catalog or network request" do
    WebMock.disable_net_connect!
    stub_request(:any, /openai\.com|opencode\.ai/)

    error = assert_raises(LiveProviderHelper::MissingCredentialError) do
      LiveProviderHelper.assert_live_availability!(
        provider: :openai,
        reference: "openai/gpt-5-nano",
        env: { LiveProviderHelper::LIVE_ENV => "1" }
      )
    end

    assert_match(/OPENAI_API_KEY/, error.message)
    assert_not_requested :any, /openai\.com|opencode\.ai/
  end

  test "canonical Go header shape carries bearer, session, and client user agent" do
    go_headers = LiveProviderHelper.request_headers(
      provider: :opencode_go,
      api_key: "test-go-key",
      session_id: "session-1"
    )

    assert_equal "Bearer test-go-key", header_value(go_headers, "authorization")
    assert_equal "session-1", header_value(go_headers, "x-opencode-session")
    assert_equal LiveProviderHelper::LIVE_USER_AGENT, header_value(go_headers, "user-agent")

    openai_headers = LiveProviderHelper.request_headers(provider: :openai, api_key: "test-openai-key")

    assert_equal "Bearer test-openai-key", header_value(openai_headers, "authorization")
    assert_nil header_value(openai_headers, "x-opencode-session")
  end

  test "perform_chat sends canonical Go headers and parses a completion" do
    url = LiveProviderHelper::CANONICAL_GO_CHAT_COMPLETIONS_URL

    stub_request(:post, url)
      .with(
        headers: {
          "Authorization" => "Bearer test-go-key",
          "x-opencode-session" => "session-1",
          "User-Agent" => LiveProviderHelper::LIVE_USER_AGENT
        }
      )
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          id: "chatcmpl-smoke",
          object: "chat.completion",
          choices: [
            { index: 0, message: { role: "assistant", content: "ok" }, finish_reason: "stop" }
          ],
          usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 }
        }.to_json
      )

    result = LiveProviderHelper.perform_chat(
      provider: :opencode_go,
      model_id: "glm-5.3-flash",
      messages: [ { role: "user", content: "Reply with exactly: ok" } ],
      api_key: "test-go-key",
      session_id: "session-1"
    )

    assert result.success?
    assert_equal "ok", result.content
    assert_requested :post, url, times: 1
  end

  test "perform_chat omits authorization when no credential is supplied" do
    captured = nil

    stub_request(:post, LiveProviderHelper::CANONICAL_GO_CHAT_COMPLETIONS_URL)
      .to_return do |request|
        captured = request.headers
        {
          status: 401,
          headers: { "Content-Type" => "application/json" },
          body: { error: { code: "invalid_api_key" } }.to_json
        }
      end

    result = LiveProviderHelper.perform_chat(
      provider: :opencode_go,
      model_id: "glm-5.3-flash",
      messages: [ { role: "user", content: "hi" } ],
      api_key: nil,
      raise_on_error: false
    )

    assert_equal 401, result.status
    assert_equal "invalid_api_key", result.safe_code
    assert_nil header_value(captured, "authorization")
  end

  test "production OpenCode Go catalog request uses the dedicated model URL with session and user agent" do
    captured = {}
    openai_url = Provider::RubyLlm::OPENAI_BASE_URL + "/models"
    go_url = Provider::RubyLlm::OPENCODE_GO_MODELS_URL

    stub_request(:get, openai_url).to_return do |request|
      captured[:openai] = request.headers
      {
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { data: [ { "id" => "gpt-5-nano" } ] }.to_json
      }
    end

    stub_request(:get, go_url).to_return do |request|
      captured[:opencode_go] = request.headers
      {
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { data: [ { "id" => "glm-5.3-flash" } ] }.to_json
      }
    end

    with_env_overrides OPENAI_API_KEY: "test-openai-key", OPENCODE_GO_API_KEY: "test-go-key" do
      catalog = Provider::RubyLlm::Catalog.new
      assert_includes catalog.available_references(:openai), "openai/gpt-5-nano"
      assert_includes catalog.available_references(:opencode_go), "opencode_go/glm-5.3-flash"
    end

    assert_equal "Bearer test-openai-key", header_value(captured[:openai], "authorization")
    assert_equal "Bearer test-go-key", header_value(captured[:opencode_go], "authorization")
    assert_match(/\Ases_[0-9a-f]{32}\z/, header_value(captured[:opencode_go], "x-opencode-session"))
    assert_equal Provider::RubyLlm::OPENCODE_GO_USER_AGENT, header_value(captured[:opencode_go], "user-agent")
  end

  test "production OpenCode Go chat request sends the canonical session and user-agent headers" do
    captured = nil
    url = Provider::RubyLlm::OPENCODE_GO_CHAT_BASE_URL + "/chat/completions"

    stub_catalog_models(:opencode_go, ids: %w[glm-5.3-flash], key: "test-go-key")

    stub_request(:post, url).to_return do |request|
      captured = request.headers
      {
        status: 200,
        headers: { "Content-Type" => "text/event-stream" },
        body: [
          "data: #{ { choices: [ { index: 0, delta: { content: "ok" } } ] }.to_json }\n\n",
          "data: #{ { choices: [ { index: 0, delta: {}, finish_reason: "stop" } ] }.to_json }\n\n",
          "data: [DONE]\n\n"
        ].join
      }
    end

    response = nil

    with_env_overrides OPENCODE_GO_API_KEY: "test-go-key" do
      response = Provider::RubyLlm.new.chat_response("Hello", model: "opencode_go/glm-5.3-flash")
    end

    assert response.success?, "expected the production Go boundary to succeed, got: #{response.error&.message}"
    assert_equal "Bearer test-go-key", header_value(captured, "authorization")
    assert_match(/\Ases_[0-9a-f]{32}\z/, header_value(captured, "x-opencode-session"))
    assert_equal Provider::RubyLlm::OPENCODE_GO_USER_AGENT, header_value(captured, "user-agent")
  end

  test "Go routing compatibility detects the legacy base, model-list path, and missing headers" do
    compatibility = LiveProviderHelper.go_routing_compatibility(
      production_api_base: "https://opencode.ai/zen/go/v1",
      production_models_url: "https://opencode.ai/zen/go/v1/models",
      production_headers: %w[Accept Authorization]
    )

    refute compatibility.compatible?
    joined = compatibility.blockers.join(" ")

    assert_match(/documented canonical Chat Completions base/, joined)
    assert_match(/documented canonical model list/, joined)
    assert_match(/x-opencode-session/, joined)
    assert_match(/client-specific User-Agent/, joined)
  end

  test "Go routing compatibility defaults to the canonical production base, model list, and headers" do
    compatibility = LiveProviderHelper.go_routing_compatibility

    assert compatibility.compatible?
    assert_empty compatibility.blockers
    assert_equal LiveProviderHelper::CANONICAL_GO_CHAT_BASE, compatibility.production_api_base
    assert_equal LiveProviderHelper::CANONICAL_GO_MODELS_URL, compatibility.production_models_url
    assert_includes compatibility.production_headers, "x-opencode-session"
    assert_includes compatibility.production_headers, "user-agent"
  end

  test "production provider boundary keeps OpenAI and OpenCode Go contexts isolated in one process" do
    configs = [ FakeConfig.new, FakeConfig.new ]
    chats = [
      FakeChat.new(FakeMessage.new("OpenAI answer", "msg_openai")),
      FakeChat.new(FakeMessage.new("Go answer", "msg_go"))
    ]
    contexts = chats.map { |chat| FakeContext.new(chat) }

    RubyLLM.stubs(:context)
      .yields(configs[0]).returns(contexts[0])
      .then.yields(configs[1]).returns(contexts[1])

    stub_catalog_models(:openai, ids: %w[gpt-5-nano], key: "openai-key")
    stub_catalog_models(:opencode_go, ids: %w[glm-5.3-flash], key: "go-key")

    openai_response = nil
    go_response = nil

    with_env_overrides OPENAI_API_KEY: "openai-key", OPENCODE_GO_API_KEY: "go-key" do
      openai_response = Provider::RubyLlm.new.chat_response("Hello", model: "openai/gpt-5-nano")
      go_response = Provider::RubyLlm.new.chat_response("Hello", model: "opencode_go/glm-5.3-flash")
    end

    assert openai_response.success?
    assert go_response.success?
    assert_equal "OpenAI answer", openai_response.data.messages.first.output_text
    assert_equal "Go answer", go_response.data.messages.first.output_text

    assert_equal "openai-key", configs[0].openai_api_key
    assert_equal Provider::RubyLlm::OPENAI_BASE_URL, configs[0].openai_api_base
    assert_equal "go-key", configs[1].openai_api_key
    assert_equal Provider::RubyLlm::OPENCODE_GO_CHAT_BASE_URL, configs[1].openai_api_base
    assert_match(/\Ases_[0-9a-f]{32}\z/, configs[1].opencode_go_session_id)
    assert_nil configs[1].openai_organization_id
    assert_nil configs[1].openai_project_id
    refute_equal configs[0].openai_api_key, configs[1].openai_api_key
    refute_equal configs[0].openai_api_base, configs[1].openai_api_base

    assert_equal "gpt-5-nano", contexts[0].options[:model]
    assert_equal :openai, contexts[0].options[:provider]
    assert_equal :chat_completions, contexts[0].options[:protocol]
    assert_equal true, contexts[0].options[:assume_model_exists]

    assert_equal "glm-5.3-flash", contexts[1].options[:model]
    assert_equal :opencode_go, contexts[1].options[:provider]
    assert_equal :chat_completions, contexts[1].options[:protocol]
    assert_equal true, contexts[1].options[:assume_model_exists]
  end

  test "with_live_network lets a synthetic request through and restores VCR and WebMock" do
    previous_webmock_net_connect = WebMock::Config.instance.allow_net_connect
    previous_vcr_turned_on = VCR.turned_on?

    with_synthetic_http_server do |url|
      uri = URI(url)
      live_vcr_turned_on = nil
      live_webmock_net_connect = nil
      response = nil

      LiveProviderHelper.with_live_network do
        live_vcr_turned_on = VCR.turned_on?
        live_webmock_net_connect = WebMock::Config.instance.allow_net_connect
        response = Net::HTTP.start(uri.host, uri.port, nil) do |http|
          http.request(Net::HTTP::Get.new(uri))
        end
      end

      refute live_vcr_turned_on, "VCR must be turned off inside the live network block"
      assert live_webmock_net_connect
      assert_equal "200", response.code
    end

    assert_nil VCR.current_cassette
    assert_equal previous_vcr_turned_on, VCR.turned_on?
    assert_config_value previous_webmock_net_connect, WebMock::Config.instance.allow_net_connect
  end

  test "with_live_network restores VCR and WebMock restrictions after exceptional and nested exits" do
    previous_webmock = {
      allow_net_connect: WebMock::Config.instance.allow_net_connect,
      allow_localhost: WebMock::Config.instance.allow_localhost,
      allow: WebMock::Config.instance.allow,
      net_http_connect_on_start: WebMock::Config.instance.net_http_connect_on_start
    }
    previous_vcr_turned_on = VCR.turned_on?

    LiveProviderHelper.with_live_network do
      assert WebMock::Config.instance.allow_net_connect
      refute VCR.turned_on?

      LiveProviderHelper.with_live_network do
        assert WebMock::Config.instance.allow_net_connect
        refute VCR.turned_on?
      end

      # An inner exit must not restore VCR while the outer block is still live.
      assert WebMock::Config.instance.allow_net_connect
      refute VCR.turned_on?
    end

    assert_raises(RuntimeError) do
      LiveProviderHelper.with_live_network do
        assert WebMock::Config.instance.allow_net_connect
        refute VCR.turned_on?
        raise "boom"
      end
    end

    assert_config_value previous_webmock[:allow_net_connect], WebMock::Config.instance.allow_net_connect
    assert_config_value previous_webmock[:allow_localhost], WebMock::Config.instance.allow_localhost
    assert_config_value previous_webmock[:allow], WebMock::Config.instance.allow
    assert_config_value previous_webmock[:net_http_connect_on_start], WebMock::Config.instance.net_http_connect_on_start
    assert_equal previous_vcr_turned_on, VCR.turned_on?
  end

  test "a disabled live gate never enables the network or yields the request block" do
    [
      { LiveProviderHelper::LIVE_ENV => "0", "OPENAI_API_KEY" => "present" },
      { LiveProviderHelper::LIVE_ENV => "1" }
    ].each do |env|
      yielded = false
      gate = LiveProviderHelper.run_live(provider: :openai, env:) do
        yielded = true
        Net::HTTP.get(URI("http://127.0.0.2:1/never"))
      end

      refute gate.enabled?
      refute yielded
      refute WebMock::Config.instance.allow_net_connect
      assert VCR.turned_on?
    end
  end

  test "SSE parsing preserves content order and usage for streaming compatibility" do
    body = [
      { choices: [ { index: 0, delta: { role: "assistant" } } ] },
      { choices: [ { index: 0, delta: { content: "o" } } ] },
      { choices: [ { index: 0, delta: { content: "k" } } ] },
      { choices: [ { index: 0, delta: {}, finish_reason: "stop" } ] },
      { choices: [], usage: { prompt_tokens: 3, completion_tokens: 1, total_tokens: 4 } },
      "[DONE]"
    ].map { |event| "data: #{event.is_a?(String) ? event : event.to_json}\n\n" }.join

    events = LiveProviderHelper.parse_sse_body(body)
    summary = LiveProviderHelper.summarize_stream(events)

    assert_equal "ok", summary.text
    assert_equal [ "o", "k" ], summary.chunks
    assert_equal [ "stop" ], summary.finish_reasons
    assert_equal({ "prompt_tokens" => 3, "completion_tokens" => 1, "total_tokens" => 4 }, summary.usage)
    assert_not_nil summary.first_content_index
    assert_not_nil summary.usage_index
    assert_operator summary.usage_index, :>, summary.first_content_index
  end

  test "SSE parsing preserves a residual event without a trailing delimiter" do
    body = "data: #{ { choices: [ { index: 0, delta: { content: "ok" } } ] }.to_json }"

    summary = LiveProviderHelper.summarize_stream(LiveProviderHelper.parse_sse_body(body))

    assert_equal "ok", summary.text
  end

  test "SSE tool-call fragments are reconstructed without executing anything" do
    body = [
      { choices: [ { index: 0, delta: { tool_calls: [ { index: 0, id: "call_1", function: { name: "echo_marker", arguments: "{\"marker\":" } } ] } } ] },
      { choices: [ { index: 0, delta: { tool_calls: [ { index: 0, function: { arguments: "\"ok\"}" } } ] } } ] },
      "[DONE]"
    ].map { |event| "data: #{event.is_a?(String) ? event : event.to_json}\n\n" }.join

    summary = LiveProviderHelper.summarize_stream(LiveProviderHelper.parse_sse_body(body))
    call = summary.tool_calls.first

    assert_equal "call_1", call["id"]
    assert_equal "echo_marker", call["name"]
    assert_equal({ "marker" => "ok" }, JSON.parse(call["arguments"]))
    assert_empty summary.chunks
  end

  test "Go live availability uses the canonical model list and rejects unlisted models" do
    url = LiveProviderHelper::CANONICAL_GO_MODELS_URL
    env = { "OPENCODE_GO_API_KEY" => "test-go-key" }

    stub_request(:get, url)
      .with(headers: { "Authorization" => "Bearer test-go-key" })
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { data: [ { "id" => "glm-5.3-flash" } ] }.to_json
      )

    assert LiveProviderHelper.assert_live_availability!(
      provider: :opencode_go,
      reference: "opencode_go/glm-5.3-flash",
      env:
    )

    stub_request(:get, url)
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { data: [ { "id" => "some-other-model" } ] }.to_json
      )

    error = assert_raises(LiveProviderHelper::AdmissionError) do
      LiveProviderHelper.assert_live_availability!(
        provider: :opencode_go,
        reference: "opencode_go/glm-5.3-flash",
        env:
      )
    end

    assert_match(/not currently admitted/, error.message)
    assert_match(/no fallback model was used/, error.message)
  end

  test "canonical Go model-list success is availability evidence, not credential validation" do
    stub_request(:get, LiveProviderHelper::CANONICAL_GO_MODELS_URL)
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { data: [ { "id" => "glm-5.3-flash" } ] }.to_json
      )

    assert LiveProviderHelper.assert_live_availability!(
      provider: :opencode_go,
      reference: "opencode_go/glm-5.3-flash",
      env: { "OPENCODE_GO_API_KEY" => "not-a-real-key" }
    )

    # Authentication is only proven by an actual chat completion; see the
    # invalid-bearer live test in test/live/llm_compatibility_test.rb.
  end
end
