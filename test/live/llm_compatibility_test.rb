require "test_helper"
require "json"
require "securerandom"

# Optional live compatibility proof for #19. Nothing here runs in routine CI:
# every test first calls require_live!, which checks KURIA_LIVE_LLM_TESTS=1 and
# the provider credential before any catalog, model-list, or provider request.
# The suite is opt-in, uses tiny prompts, performs no retries, and never sends
# real financial data (the only tool is a local echo marker).
class LiveLlmCompatibilityTest < ActiveSupport::TestCase
  SIMPLE_PROMPT = "Reply with exactly: ok".freeze
  ROLE_PROMPT = "Reply with exactly: role-ok".freeze
  STRUCTURED_PROMPT = "Return only the JSON object required by the schema, with status ok.".freeze

  def require_live!(provider)
    gate = LiveProviderHelper.live_gate(provider:)
    skip(gate.reason) unless gate.enabled?
  end

  def explicit_reference!(provider)
    LiveProviderHelper.live_model_reference!(provider)
  end

  def model_id_for(reference)
    reference.split("/", 2).last
  end

  def perform_for(provider, reference, messages:, **options)
    LiveProviderHelper.perform_chat(
      provider:,
      model_id: model_id_for(reference),
      messages:,
      api_key: LiveProviderHelper.credential_for(provider),
      **options
    )
  end

  def failure_detail(result)
    result.safe_code.present? ? " (#{result.safe_code})" : ""
  end

  def assert_http_success!(result, label)
    assert result.success?, "#{label} failed with HTTP #{result.status}#{failure_detail(result)}"
  end

  def assert_json_completion!(result, label)
    assert_http_success!(result, label)
    content = result.content
    assert content.is_a?(String) && content.present?, "#{label} returned no assistant content"
    content
  end

  def assert_stream_usage!(result, label)
    assert_not_nil result.usage, "#{label} did not include stream usage"
    assert_not_nil result.first_content_index, "#{label} did not stream assistant content"
    assert_not_nil result.usage_index, "#{label} did not report a usage event"
    assert_operator result.usage_index, :>=, result.first_content_index

    assert_kind_of Integer, result.usage["prompt_tokens"]
    assert_kind_of Integer, result.usage["completion_tokens"]
    assert_kind_of Integer, result.usage["total_tokens"]
    assert_operator result.usage["total_tokens"], :>, 0
  end

  test "OpenAI and OpenCode Go are selected independently from explicit env references in one process" do
    require_live!(:openai)
    require_live!(:opencode_go)

    openai_reference = explicit_reference!(:openai)
    go_reference = explicit_reference!(:opencode_go)

    assert openai_reference.start_with?("openai/")
    assert go_reference.start_with?("opencode_go/")
    refute_equal openai_reference, go_reference

    LiveProviderHelper.with_live_network do
      LiveProviderHelper.assert_live_availability!(provider: :openai, reference: openai_reference)
      LiveProviderHelper.assert_live_availability!(provider: :opencode_go, reference: go_reference)

      openai = perform_for(
        :openai,
        openai_reference,
        messages: [ { role: "user", content: "Reply with exactly: openai-ok" } ]
      )
      go = perform_for(
        :opencode_go,
        go_reference,
        messages: [ { role: "user", content: "Reply with exactly: go-ok" } ]
      )

      assert_match(/openai-ok/i, assert_json_completion!(openai, "OpenAI independent completion"))
      assert_match(/go-ok/i, assert_json_completion!(go, "OpenCode Go independent completion"))
    end
  end

  test "OpenAI provider boundary accepts developer instructions" do
    require_live!(:openai)
    reference = explicit_reference!(:openai)

    LiveProviderHelper.with_live_network do
      LiveProviderHelper.assert_live_availability!(provider: :openai, reference:)

      response = Provider::RubyLlm.new.chat_response(
        "Reply with exactly: provider-ok",
        model: reference,
        instructions: "Follow the user's instruction exactly."
      )

      assert response.success?, "OpenAI provider boundary failed: #{response.error&.message}"
      assert_match(/provider-ok/i, response.data.messages.first.output_text)
    end
  end

  test "OpenAI direct Chat Completions accepts a developer role" do
    require_live!(:openai)
    reference = explicit_reference!(:openai)

    LiveProviderHelper.with_live_network do
      LiveProviderHelper.assert_live_availability!(provider: :openai, reference:)

      result = perform_for(
        :openai,
        reference,
        messages: [
          { role: "developer", content: "Follow the user's instruction exactly." },
          { role: "user", content: ROLE_PROMPT }
        ]
      )

      assert_match(/role-ok/i, assert_json_completion!(result, "OpenAI developer role"))
    end
  end

  test "OpenAI streams ordered content and usage" do
    require_live!(:openai)
    reference = explicit_reference!(:openai)

    LiveProviderHelper.with_live_network do
      LiveProviderHelper.assert_live_availability!(provider: :openai, reference:)

      result = perform_for(
        :openai,
        reference,
        messages: [ { role: "user", content: SIMPLE_PROMPT } ],
        stream: true
      )

      assert_http_success!(result, "OpenAI streaming")
      assert_operator result.chunks.size, :>=, 1
      assert_equal result.chunks.join, result.text
      assert_match(/ok/i, result.text)
      assert_stream_usage!(result, "OpenAI streaming")
    end
  end

  test "OpenAI accepts one harmless local tool call" do
    require_live!(:openai)
    reference = explicit_reference!(:openai)
    marker = "kuria-openai-tool"

    LiveProviderHelper.with_live_network do
      LiveProviderHelper.assert_live_availability!(provider: :openai, reference:)

      result = perform_for(
        :openai,
        reference,
        messages: [
          {
            role: "user",
            content: "Call echo_marker with marker #{marker.inspect}. Do not answer with text."
          }
        ],
        tools: [ LiveProviderHelper.smoke_tool_definition ],
        tool_choice: "auto"
      )

      assert_http_success!(result, "OpenAI tool call")
      calls = result.json.dig("choices", 0, "message", "tool_calls")
      assert_kind_of Array, calls

      call = calls.find { |entry| entry.is_a?(Hash) && entry.dig("function", "name") == "echo_marker" }
      refute_nil call, "OpenAI did not call the harmless echo_marker tool"

      arguments = JSON.parse(call.dig("function", "arguments").to_s)
      assert_equal marker, arguments["marker"]
    end
  end

  test "OpenAI returns a strict structured response" do
    require_live!(:openai)
    reference = explicit_reference!(:openai)

    LiveProviderHelper.with_live_network do
      LiveProviderHelper.assert_live_availability!(provider: :openai, reference:)

      result = perform_for(
        :openai,
        reference,
        messages: [ { role: "user", content: STRUCTURED_PROMPT } ],
        response_format: LiveProviderHelper.strict_smoke_response_format
      )

      parsed = JSON.parse(assert_json_completion!(result, "OpenAI structured response"))
      assert_equal({ "status" => "ok" }, parsed)
    end
  end

  test "OpenCode Go canonical Chat Completions accepts bearer auth, session, client user agent, and system instructions" do
    require_live!(:opencode_go)
    reference = explicit_reference!(:opencode_go)
    session_id = SecureRandom.uuid

    LiveProviderHelper.with_live_network do
      LiveProviderHelper.assert_live_availability!(provider: :opencode_go, reference:)

      result = perform_for(
        :opencode_go,
        reference,
        messages: [
          { role: "system", content: "Follow the user's instruction exactly." },
          { role: "user", content: ROLE_PROMPT }
        ],
        session_id:
      )

      assert_match(/role-ok/i, assert_json_completion!(result, "OpenCode Go system role"))
    end
  end

  test "OpenCode Go rejects an invalid bearer credential" do
    require_live!(:opencode_go)
    reference = explicit_reference!(:opencode_go)

    LiveProviderHelper.with_live_network do
      result = LiveProviderHelper.perform_chat(
        provider: :opencode_go,
        model_id: model_id_for(reference),
        messages: [ { role: "user", content: SIMPLE_PROMPT } ],
        api_key: "invalid-live-smoke-token",
        session_id: SecureRandom.uuid,
        raise_on_error: false
      )

      assert_includes(
        [ 401, 403 ],
        result.status,
        "expected OpenCode Go to reject an invalid bearer credential, got HTTP " \
        "#{result.status}#{failure_detail(result)}"
      )
    end
  end

  test "OpenCode Go streams ordered content and usage" do
    require_live!(:opencode_go)
    reference = explicit_reference!(:opencode_go)

    LiveProviderHelper.with_live_network do
      LiveProviderHelper.assert_live_availability!(provider: :opencode_go, reference:)

      result = perform_for(
        :opencode_go,
        reference,
        messages: [ { role: "user", content: SIMPLE_PROMPT } ],
        stream: true,
        session_id: SecureRandom.uuid
      )

      assert_http_success!(result, "OpenCode Go streaming")
      assert_operator result.chunks.size, :>=, 1
      assert_equal result.chunks.join, result.text
      assert_match(/ok/i, result.text)
      assert_stream_usage!(result, "OpenCode Go streaming")
    end
  end

  test "OpenCode Go accepts one harmless local tool call" do
    require_live!(:opencode_go)
    reference = explicit_reference!(:opencode_go)
    marker = "kuria-go-tool"

    LiveProviderHelper.with_live_network do
      LiveProviderHelper.assert_live_availability!(provider: :opencode_go, reference:)

      result = perform_for(
        :opencode_go,
        reference,
        messages: [
          {
            role: "user",
            content: "Call echo_marker with marker #{marker.inspect}. Do not answer with text."
          }
        ],
        tools: [ LiveProviderHelper.smoke_tool_definition ],
        tool_choice: "auto",
        session_id: SecureRandom.uuid
      )

      assert_http_success!(result, "OpenCode Go tool call")
      calls = result.json.dig("choices", 0, "message", "tool_calls")
      assert_kind_of Array, calls

      call = calls.find { |entry| entry.is_a?(Hash) && entry.dig("function", "name") == "echo_marker" }
      refute_nil call, "OpenCode Go did not call the harmless echo_marker tool"

      arguments = JSON.parse(call.dig("function", "arguments").to_s)
      assert_equal marker, arguments["marker"]
    end
  end

  test "OpenCode Go returns a strict structured response" do
    require_live!(:opencode_go)
    reference = explicit_reference!(:opencode_go)

    LiveProviderHelper.with_live_network do
      LiveProviderHelper.assert_live_availability!(provider: :opencode_go, reference:)

      result = perform_for(
        :opencode_go,
        reference,
        messages: [ { role: "user", content: STRUCTURED_PROMPT } ],
        response_format: LiveProviderHelper.strict_smoke_response_format,
        session_id: SecureRandom.uuid
      )

      parsed = JSON.parse(assert_json_completion!(result, "OpenCode Go structured response"))
      assert_equal({ "status" => "ok" }, parsed)
    end
  end

  test "OpenCode Go production routing incompatibility is reported instead of claiming parity" do
    require_live!(:opencode_go)
    reference = explicit_reference!(:opencode_go)
    compatibility = LiveProviderHelper.go_routing_compatibility

    unless compatibility.compatible?
      skip(
        "OpenCode Go production parity is NOT claimed by #19. Production routing is unchanged; " \
        "the documented canonical transport is verified separately by this live file. Blockers: " \
        "#{compatibility.blockers.join('; ')}"
      )
    end

    LiveProviderHelper.with_live_network do
      LiveProviderHelper.assert_live_availability!(provider: :opencode_go, reference:)

      response = Provider::RubyLlm.new.chat_response(SIMPLE_PROMPT, model: reference)
      assert response.success?, "OpenCode Go provider boundary failed: #{response.error&.message}"
      assert_match(/ok/i, response.data.messages.first.output_text)
    end
  end
end
