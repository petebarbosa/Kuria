require "json"
require "net/http"
require "securerandom"
require "uri"

# Shared plumbing for the explicitly enabled live LLM compatibility smoke
# tests (#19). Nothing here is called from application code: it is loaded only
# from the test suite, and every live operation must pass the gate in
# #live_gate before a credential, catalog request, or provider request is
# touched.
#
# The harness deliberately uses the documented Chat Completions protocol
# directly for protocol-level checks (streaming usage, roles, tools, strict
# structured output) and uses Kuria's public Provider::RubyLlm boundary where
# that boundary can express the check. It never prints or returns a credential.
module LiveProviderHelper
  LIVE_ENV = "KURIA_LIVE_LLM_TESTS".freeze
  OPENAI_CREDENTIAL = "OPENAI_API_KEY".freeze
  OPENCODE_GO_CREDENTIAL = "OPENCODE_GO_API_KEY".freeze
  OPENAI_MODEL_ENV = "KURIA_LIVE_OPENAI_MODEL".freeze
  OPENCODE_GO_MODEL_ENV = "KURIA_LIVE_OPENCODE_GO_MODEL".freeze

  LIVE_USER_AGENT = "kuria-live-compatibility-smoke/1.0".freeze

  HTTP_OPEN_TIMEOUT_SECONDS = 5
  HTTP_READ_TIMEOUT_SECONDS = 60
  HTTP_WRITE_TIMEOUT_SECONDS = 10
  MAX_OUTPUT_TOKENS = 64
  MAX_ERROR_BODY_BYTES = 4096

  # Documented endpoints, verified against
  # https://opencode.ai/v2/docs/console/go and
  # https://opencode.ai/v2/docs/console/api/inference.
  CANONICAL_OPENAI_CHAT_COMPLETIONS_URL = "https://api.openai.com/v1/chat/completions".freeze
  CANONICAL_OPENAI_MODELS_URL = "https://api.openai.com/v1/models".freeze
  CANONICAL_GO_CHAT_BASE = "https://opencode.ai/inference/go/openai/v1".freeze
  CANONICAL_GO_CHAT_COMPLETIONS_URL = "#{CANONICAL_GO_CHAT_BASE}/chat/completions".freeze
  CANONICAL_GO_MODELS_URL = "https://opencode.ai/inference/go/v1/models".freeze

  # Headers sent by Kuria's production OpenCode Go catalog and chat transport.
  # The routing compatibility check compares these names with the canonical
  # transport so a regression is reported instead of silently skipping.
  PRODUCTION_GO_HEADER_NAMES = %w[Accept Authorization x-opencode-session User-Agent].freeze

  ACCOUNT_CONFIG = {
    openai: {
      reference_prefix: "openai/",
      credential: OPENAI_CREDENTIAL,
      model_env: OPENAI_MODEL_ENV,
      chat_url: CANONICAL_OPENAI_CHAT_COMPLETIONS_URL,
      models_url: CANONICAL_OPENAI_MODELS_URL,
      api_base: "https://api.openai.com/v1".freeze,
      max_tokens_field: :max_completion_tokens
    },
    opencode_go: {
      reference_prefix: "opencode_go/",
      credential: OPENCODE_GO_CREDENTIAL,
      model_env: OPENCODE_GO_MODEL_ENV,
      chat_url: CANONICAL_GO_CHAT_COMPLETIONS_URL,
      models_url: CANONICAL_GO_MODELS_URL,
      api_base: CANONICAL_GO_CHAT_BASE,
      max_tokens_field: :max_tokens
    }
  }.freeze

  # OpenCode Go model IDs documented as served by Responses, Anthropic
  # Messages, or Gemini. They are deliberately absent from Kuria's verified
  # Chat Completions manifest, and the harness must reject them clearly rather
  # than silently choosing another model.
  UNSUPPORTED_GO_MODELS = {
    "grok-4.7" => "Responses API",
    "gpt-6-luna" => "Responses API",
    "gpt-5.6-luna" => "Responses API",
    "muse-spark-1.3-contributor" => "Responses API",
    "muse-spark-1.2-contributor" => "Responses API",
    "claude-haiku-5-5" => "Anthropic Messages API",
    "minimax-m3" => "Anthropic Messages API",
    "qwen3.8-max" => "Anthropic Messages API",
    "qwen3.8-flash" => "Anthropic Messages API",
    "qwen3.7-plus" => "Anthropic Messages API",
    "gemini-4-argon-contributor" => "Gemini API"
  }.freeze

  class Error < StandardError; end
  class ConfigurationError < Error; end
  class MissingCredentialError < ConfigurationError; end
  class MissingModelReferenceError < ConfigurationError; end
  class UnsupportedModelError < Error; end
  class AdmissionError < Error; end

  class ProviderError < Error
    attr_reader :provider, :status, :safe_code

    def initialize(provider:, status:, safe_code: nil)
      @provider = provider
      @status = status
      @safe_code = safe_code
      suffix = safe_code.present? ? " (#{safe_code})" : ""
      super("Live #{provider} request failed with HTTP #{status}#{suffix}.")
    end
  end

  Gate = Struct.new(:enabled, :reason, keyword_init: true) do
    def enabled?
      !!enabled
    end
  end

  JsonResult = Struct.new(:status, :body, :safe_code, keyword_init: true) do
    def success?
      status.between?(200, 299)
    end

    def json
      @json ||= JSON.parse(body.to_s)
    end

    def content
      json.dig("choices", 0, "message", "content")
    end
  end

  StreamSummary = Struct.new(
    :events, :chunks, :text, :usage, :usage_index, :first_content_index,
    :finish_reasons, :tool_calls,
    keyword_init: true
  )

  StreamResult = Struct.new(
    :status, :events, :chunks, :text, :usage, :usage_index, :first_content_index,
    :finish_reasons, :tool_calls, :safe_code,
    keyword_init: true
  ) do
    def success?
      status.between?(200, 299)
    end
  end

  RoutingCompatibility = Struct.new(
    :production_api_base, :canonical_api_base,
    :production_models_url, :canonical_models_url,
    :production_headers, :blockers,
    keyword_init: true
  ) do
    def compatible?
      blockers.empty?
    end
  end

  module_function

  # The single gate every live test must pass. It checks only the explicit
  # opt-in flag and credential presence; it never reads, compares, or copies a
  # credential value into a result or message.
  def live_gate(provider:, env: ENV)
    config = account_config(provider)

    unless env[LIVE_ENV].to_s == "1"
      return Gate.new(
        enabled: false,
        reason: "Live LLM tests are disabled. Set #{LIVE_ENV}=1 to enable them."
      )
    end

    if env[config[:credential]].to_s.strip.empty?
      return Gate.new(
        enabled: false,
        reason: "Live #{provider} tests are disabled: #{config[:credential]} is not set."
      )
    end

    Gate.new(enabled: true, reason: nil)
  end

  # Runs a block only after the gate passes. Useful for proving that a disabled
  # suite never reaches catalog or network work.
  def run_live(provider:, env: ENV)
    gate = live_gate(provider:, env:)
    return gate unless gate.enabled?

    yield gate
  end

  def account_config(provider)
    ACCOUNT_CONFIG.fetch(provider.to_sym) do
      raise ArgumentError, "Unknown live provider #{provider.inspect}. Expected :openai or :opencode_go."
    end
  end

  # Returns the credential value for an actual live request. Callers must have
  # passed the gate first and must never print the returned value.
  def credential_for(provider, env: ENV)
    config = account_config(provider)
    value = env[config[:credential]].to_s.strip

    if value.empty?
      raise MissingCredentialError, "Missing #{config[:credential]}. Set it to run live #{provider} tests."
    end

    value
  end

  # Reads the explicit per-provider model reference. There is intentionally no
  # fallback or default: absent env configuration is a configuration error.
  def live_model_reference!(provider, env: ENV)
    config = account_config(provider)
    reference = env[config[:model_env]].to_s.strip

    if reference.empty?
      raise MissingModelReferenceError,
        "Set #{config[:model_env]} to an explicit #{config[:reference_prefix]}<model> reference. " \
        "This harness never selects a model automatically."
    end

    validate_reference!(provider:, reference:)
  end

  # Static validation only: requires an explicit provider reference, rejects
  # known Responses/Anthropic/Gemini references, and requires membership in
  # Kuria's immutable Chat Completions manifest.
  def validate_reference!(provider:, reference:)
    config = account_config(provider)
    ref = reference.to_s.strip

    if ref.empty?
      raise UnsupportedModelError,
        "Explicit #{provider} model reference is blank. Set #{config[:model_env]} to a " \
        "#{config[:reference_prefix]}<model> reference; no model was substituted."
    end

    unless ref.start_with?(config[:reference_prefix])
      raise UnsupportedModelError,
        "Unsupported model reference #{ref.inspect} for provider '#{provider}'. " \
        "Expected an explicit #{config[:reference_prefix]}<model> reference; no model was substituted."
    end

    model_id = ref.delete_prefix(config[:reference_prefix])

    if model_id.empty? || model_id.include?("/")
      raise UnsupportedModelError,
        "Unsupported model reference #{ref.inspect} for provider '#{provider}'. " \
        "Expected exactly one non-empty model ID after #{config[:reference_prefix]}; no model was substituted."
    end

    if (api = unsupported_api_for(provider, model_id))
      raise UnsupportedModelError,
        "#{ref} is served by the #{api}, not Chat Completions. Kuria's verified RubyLLM path " \
        "supports Chat Completions only; this harness will not downgrade or substitute a model."
    end

    unless Provider::RubyLlm::Catalog.admits?(ref)
      raise UnsupportedModelError,
        "#{ref} is not in Kuria's verified Chat Completions catalog. Responses-only and " \
        "Anthropic Messages references are unsupported by this harness; no model was substituted."
    end

    ref
  end

  # Live availability check. A successful model-list request is NOT credential
  # validation: OpenAI and OpenCode Go both expose model lists that can return
  # 200 even when a chat request would be unauthorized. Authentication is
  # proven separately by an actual chat completion.
  def assert_live_availability!(provider:, reference:, env: ENV)
    config = account_config(provider)
    validate_reference!(provider:, reference:)
    credential = credential_for(provider, env:)

    case provider.to_sym
    when :openai
      assert_openai_live_availability!(reference)
    when :opencode_go
      model_id = reference.delete_prefix(config[:reference_prefix])
      ids = canonical_go_model_ids(api_key: credential)

      unless ids.include?(model_id)
        raise AdmissionError,
          "OpenCode Go model '#{model_id}' is catalogued but was not returned by the canonical " \
          "model list #{CANONICAL_GO_MODELS_URL}. It is not currently admitted; no fallback model was used."
      end
    end

    true
  end

  def assert_openai_live_availability!(reference)
    admitted = Provider::RubyLlm::Catalog.new.available?(reference)

    unless admitted
      raise AdmissionError,
        "OpenAI model '#{reference}' is catalogued but was not admitted by the live OpenAI model list. " \
        "It is not currently available; no fallback model was used."
    end

    true
  rescue Provider::RubyLlm::Catalog::Error => e
    raise AdmissionError,
      "OpenAI live model list lookup failed: #{e.message} " \
      "A model-list response is availability evidence only, never credential validation."
  end

  def canonical_go_model_ids(api_key:, session_id: nil)
    config = account_config(:opencode_go)
    result = get_json(
      url: config[:models_url],
      headers: request_headers(provider: :opencode_go, api_key:, session_id:)
    )

    unless result.success?
      raise AdmissionError,
        "OpenCode Go canonical model list failed with HTTP #{result.status}" \
        "#{result.safe_code.present? ? " (#{result.safe_code})" : ""}; no fallback model was used."
    end

    entries = result.json["data"]

    unless entries.is_a?(Array) && entries.all? { |entry| entry.is_a?(Hash) && entry["id"].is_a?(String) && entry["id"].present? }
      raise AdmissionError,
        "OpenCode Go canonical model list returned an unexpected response shape; expected a 'data' " \
        "array of models carrying string 'id' values. No fallback model was used."
    end

    entries.map { |entry| entry["id"] }
  end

  def request_headers(provider:, api_key:, session_id: nil)
    headers = {
      "Accept" => "application/json",
      "Content-Type" => "application/json",
      "User-Agent" => LIVE_USER_AGENT
    }

    headers["Authorization"] = "Bearer #{api_key}" if api_key.present?

    if provider.to_sym == :opencode_go
      headers["x-opencode-session"] = session_id.presence || SecureRandom.uuid
    end

    headers
  end

  # Performs one bounded Chat Completions request. No retries are implemented
  # here, and the caller chooses a tiny prompt/output budget.
  def perform_chat(provider:, model_id:, messages:, api_key:, session_id: nil,
                   stream: false, tools: nil, tool_choice: nil, response_format: nil,
                   max_output_tokens: MAX_OUTPUT_TOKENS, raise_on_error: true)
    config = account_config(provider)
    headers = request_headers(provider:, api_key:, session_id:)
    payload = chat_payload(
      provider:, model_id:, messages:, stream:, tools:, tool_choice:,
      response_format:, max_output_tokens:
    )

    result = if stream
      post_sse(url: config[:chat_url], headers:, payload:)
    else
      post_json(url: config[:chat_url], headers:, payload:)
    end

    if raise_on_error && !result.success?
      raise ProviderError.new(provider:, status: result.status, safe_code: result.safe_code)
    end

    result
  end

  def chat_payload(provider:, model_id:, messages:, stream:, tools: nil, tool_choice: nil,
                   response_format: nil, max_output_tokens: MAX_OUTPUT_TOKENS)
    config = account_config(provider)
    payload = { model: model_id, messages: messages, stream: stream }

    payload[config[:max_tokens_field]] = max_output_tokens unless max_output_tokens.nil?
    payload[:tools] = tools if tools.present?
    payload[:tool_choice] = tool_choice if tool_choice.present?
    payload[:response_format] = response_format if response_format.present?
    payload[:stream_options] = { include_usage: true } if stream

    payload
  end

  def smoke_tool_definition
    {
      type: "function",
      function: {
        name: "echo_marker",
        description: "Return the supplied marker unchanged. This is a local, harmless smoke-test tool.",
        parameters: {
          type: "object",
          properties: {
            marker: { type: "string", description: "A short marker to echo." }
          },
          required: [ "marker" ],
          additionalProperties: false
        }
      }
    }
  end

  def strict_smoke_response_format
    {
      type: "json_schema",
      json_schema: {
        name: "kuria_live_smoke_result",
        strict: true,
        schema: {
          type: "object",
          properties: {
            status: { type: "string", enum: [ "ok" ] }
          },
          required: [ "status" ],
          additionalProperties: false
        }
      }
    }
  end

  # Compares Kuria's production OpenCode Go routing with the documented
  # canonical endpoints. A non-empty blockers list means parity is NOT proven;
  # callers must report it instead of claiming success.
  def go_routing_compatibility(production_api_base: nil, production_models_url: nil,
                               production_headers: nil)
    base = (production_api_base || Provider::RubyLlm::OPENCODE_GO_CHAT_BASE_URL).to_s.delete_suffix("/")
    models_url = (production_models_url || Provider::RubyLlm::OPENCODE_GO_MODELS_URL).to_s.delete_suffix("/")
    headers = Array(production_headers || PRODUCTION_GO_HEADER_NAMES).map { |name| name.to_s.downcase }
    blockers = []

    unless base == CANONICAL_GO_CHAT_BASE
      blockers << "production OpenCode Go API base #{base} is not the documented canonical " \
                  "Chat Completions base #{CANONICAL_GO_CHAT_BASE}"
    end

    unless models_url == CANONICAL_GO_MODELS_URL
      blockers << "production OpenCode Go model list URL #{models_url} is not the documented " \
                  "canonical model list #{CANONICAL_GO_MODELS_URL}"
    end

    unless headers.include?("x-opencode-session")
      blockers << "production OpenCode Go transport does not send x-opencode-session"
    end

    unless headers.include?("user-agent")
      blockers << "production OpenCode Go transport does not send a client-specific User-Agent"
    end

    RoutingCompatibility.new(
      production_api_base: base,
      canonical_api_base: CANONICAL_GO_CHAT_BASE,
      production_models_url: models_url,
      canonical_models_url: CANONICAL_GO_MODELS_URL,
      production_headers: headers,
      blockers:
    )
  end

  # Live tests opt into real network access only inside this block. VCR is
  # configured to hook WebMock (test/test_helper.rb) and blocks every request
  # while it is turned on without a cassette, even when WebMock allows net
  # connections. VCR is therefore turned off for the block and is never given
  # a cassette, so nothing is recorded. The previous VCR and WebMock states
  # are restored even when the block raises; for nested blocks the outermost
  # state is the one restored.
  def with_live_network
    config = WebMock::Config.instance
    previous = {
      allow_net_connect: config.allow_net_connect,
      allow_localhost: config.allow_localhost,
      allow: config.allow,
      net_http_connect_on_start: config.net_http_connect_on_start
    }
    vcr_was_turned_on = VCR.turned_on?

    VCR.turn_off! if vcr_was_turned_on
    WebMock.allow_net_connect!
    yield
  ensure
    VCR.turn_on! if defined?(VCR) && vcr_was_turned_on

    WebMock.reset! if defined?(WebMock)
    if defined?(WebMock) && config && previous
      config.allow_net_connect = previous[:allow_net_connect]
      config.allow_localhost = previous[:allow_localhost]
      config.allow = previous[:allow]
      config.net_http_connect_on_start = previous[:net_http_connect_on_start]
    end
  end

  def get_json(url:, headers:)
    perform_http(method: :get, url:, headers:, payload: nil)
  end

  def post_json(url:, headers:, payload:)
    perform_http(method: :post, url:, headers:, payload:)
  end

  def perform_http(method:, url:, headers:, payload:)
    uri = URI.parse(url)
    request = method.to_sym == :get ? Net::HTTP::Get.new(uri) : Net::HTTP::Post.new(uri)
    headers.each { |name, value| request[name] = value }
    request.body = JSON.generate(payload) if payload

    response = http_for(uri).start { |http| http.request(request) }
    status = response.code.to_i
    body = response.body.to_s

    JsonResult.new(
      status:,
      body: status.between?(200, 299) ? body : nil,
      safe_code: safe_error_code(body)
    )
  end

  def post_sse(url:, headers:, payload:)
    uri = URI.parse(url)
    request = Net::HTTP::Post.new(uri)
    headers.each { |name, value| request[name] = value }
    request.body = JSON.generate(payload)

    status = nil
    events = []
    error_body = +""
    buffer = +""

    http_for(uri).start do |http|
      http.request(request) do |response|
        status = response.code.to_i

        if status.between?(200, 299)
          response.read_body do |chunk|
            buffer << chunk
            consume_sse_buffer(buffer, events)
          end
        else
          response.read_body do |chunk|
            error_body << chunk if error_body.bytesize < MAX_ERROR_BODY_BYTES
          end
        end
      end
    end

    consume_sse_buffer(buffer, events)
    event = parse_sse_event(buffer)
    events << event if event
    summary = summarize_stream(events)

    StreamResult.new(
      status: status || 0,
      events: summary.events,
      chunks: summary.chunks,
      text: summary.text,
      usage: summary.usage,
      usage_index: summary.usage_index,
      first_content_index: summary.first_content_index,
      finish_reasons: summary.finish_reasons,
      tool_calls: summary.tool_calls,
      safe_code: safe_error_code(error_body)
    )
  end

  def parse_sse_body(body)
    events = []
    scanner = body.to_s.dup
    consume_sse_buffer(scanner, events)

    event = parse_sse_event(scanner)
    events << event if event

    events
  end

  # Turns ordered Chat Completions chunks into ordered content, finish reasons,
  # tool-call fragments, and the usage object. It intentionally does not
  # invent or retry missing data.
  def summarize_stream(events)
    chunks = []
    text = +""
    usage = nil
    usage_index = nil
    first_content_index = nil
    finish_reasons = []
    tool_calls = {}

    events.each_with_index do |event, index|
      next unless event.is_a?(Hash)

      if event["usage"].is_a?(Hash)
        usage = event["usage"]
        usage_index = index
      end

      choices = event["choices"]
      next unless choices.is_a?(Array)

      choices.each do |choice|
        next unless choice.is_a?(Hash)

        finish_reasons << choice["finish_reason"] if choice["finish_reason"].is_a?(String)

        delta = choice["delta"] || choice["message"] || {}
        next unless delta.is_a?(Hash)

        content = delta["content"]
        if content.is_a?(String) && !content.empty?
          first_content_index ||= index
          chunks << content
          text << content
        end

        collect_stream_tool_calls(tool_calls, delta["tool_calls"])
      end
    end

    StreamSummary.new(
      events:,
      chunks:,
      text:,
      usage:,
      usage_index:,
      first_content_index:,
      finish_reasons:,
      tool_calls: tool_calls.values
    )
  end

  def consume_sse_buffer(buffer, events)
    while (match = buffer.match(/\r?\n\r?\n/))
      raw = buffer.slice!(0, match.end(0))
      event = parse_sse_event(raw)
      events << event if event
    end
  end

  def parse_sse_event(raw)
    data = raw.to_s.lines.filter_map do |line|
      next unless line.start_with?("data:")

      line.sub(/\Adata:\s?/, "").rstrip
    end.join("\n")

    return nil if data.empty? || data == "[DONE]"

    parsed = JSON.parse(data)
    parsed.is_a?(Hash) ? parsed : nil
  rescue JSON::ParserError
    nil
  end

  def collect_stream_tool_calls(tool_calls, calls)
    return unless calls.is_a?(Array)

    calls.each do |call|
      next unless call.is_a?(Hash)

      key = call["index"] || call["id"] || tool_calls.size
      entry = tool_calls[key] ||= { "id" => nil, "name" => nil, "arguments" => +"" }

      entry["id"] = call["id"] if call["id"].is_a?(String) && entry["id"].nil?

      function = call["function"]
      next unless function.is_a?(Hash)

      entry["name"] = function["name"] if function["name"].is_a?(String) && entry["name"].nil?
      entry["arguments"] << function["arguments"] if function["arguments"].is_a?(String)
    end
  end

  def safe_error_code(body)
    return nil if body.to_s.empty?

    parsed = JSON.parse(body.to_s)
    return nil unless parsed.is_a?(Hash)

    error = parsed["error"]
    return nil unless error.is_a?(Hash)

    code = error["code"] || error["type"]
    code.to_s[0, 80] if code.present?
  rescue JSON::ParserError
    nil
  end

  def http_for(uri)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = HTTP_OPEN_TIMEOUT_SECONDS
    http.read_timeout = HTTP_READ_TIMEOUT_SECONDS
    http.write_timeout = HTTP_WRITE_TIMEOUT_SECONDS if http.respond_to?(:write_timeout=)
    http
  end

  def unsupported_api_for(provider, model_id)
    return nil unless provider.to_sym == :opencode_go

    UNSUPPORTED_GO_MODELS[model_id]
  end
end
