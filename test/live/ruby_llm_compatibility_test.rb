require "test_helper"
require "json"

# Bounded live compatibility checks through Kuria's production Provider::RubyLlm
# seam (#19). Unlike the direct Chat Completions HTTP harness in
# llm_compatibility_test.rb, these tests exercise the adapter contract the
# application actually uses: streaming assembly, tool execution, structured
# output, and explicit provider/model resolution.
#
# Opt-in only. Every live test checks KURIA_LIVE_LLM_TESTS=1 and the provider
# credential before catalog or network work. Routine CI skips them because the
# flag is absent. The file also contains one deterministic gate assertion that
# never touches the network.
class RubyLlmCompatibilityTest < ActiveSupport::TestCase
  SIMPLE_PROMPT = "Reply with exactly: seam-ok".freeze
  TOOL_PROMPT = "Call the echo_marker_seam tool exactly once with marker \"seam-tool\", then reply with exactly: tool-ok".freeze

  # A local, harmless tool used to prove that RubyLLM actually executes a
  # production-seam tool call. It returns only the supplied marker.
  class EchoMarkerTool < RubyLLM::Tool
    description "Return the supplied marker unchanged. Harmless local live-smoke tool."
    parameter :marker, description: "A short marker to echo."

    def self.tool_name
      "echo_marker_seam"
    end

    attr_reader :calls

    def initialize
      @calls = []
      super
    end

    def execute(marker:)
      @calls << marker
      { "marker" => marker, "executed" => true }
    end
  end

  def require_live!(provider)
    gate = LiveProviderHelper.live_gate(provider:)
    skip(gate.reason) unless gate.enabled?
  end

  def explicit_reference!(provider)
    LiveProviderHelper.live_model_reference!(provider)
  end

  def provider
    @provider ||= Provider::RubyLlm.new
  end

  def assert_success!(response, label)
    assert response.success?, "#{label} failed: #{response.error&.message}"
    response.data
  end

  test "live gate blocks production seam work before catalog or network" do
    yielded = false

    disabled = LiveProviderHelper.run_live(
      provider: :openai,
      env: { LiveProviderHelper::LIVE_ENV => "0" }
    ) { yielded = true }

    refute disabled.enabled?
    assert_match(/KURIA_LIVE_LLM_TESTS=1/, disabled.reason)
    refute yielded

    missing_credential = LiveProviderHelper.run_live(
      provider: :openai,
      env: { LiveProviderHelper::LIVE_ENV => "1" }
    ) { yielded = true }

    refute missing_credential.enabled?
    assert_match(/OPENAI_API_KEY/, missing_credential.reason)
    refute yielded
  end

  test "OpenAI production seam keeps streamed text consistent with the final response" do
    require_live!(:openai)
    reference = explicit_reference!(:openai)
    chunks = []

    LiveProviderHelper.with_live_network do
      response = provider.chat_response(
        SIMPLE_PROMPT,
        model: reference,
        streamer: ->(chunk) { chunks << chunk }
      )

      data = assert_success!(response, "OpenAI production streaming")
      final_text = data.messages.first.output_text
      streamed_text = chunks
        .select { |chunk| chunk.type == "output_text" }
        .map(&:data)
        .join

      assert_equal final_text, streamed_text
      assert_match(/seam-ok/i, final_text)

      final_chunks = chunks.select { |chunk| chunk.type == "response" }
      assert_equal 1, final_chunks.size
      assert_same data, final_chunks.first.data
    end
  end

  test "OpenAI production seam executes a harmless local tool and audits the result" do
    require_live!(:openai)
    reference = explicit_reference!(:openai)
    tool = EchoMarkerTool.new
    audits = []

    LiveProviderHelper.with_live_network do
      response = provider.chat_response(
        TOOL_PROMPT,
        model: reference,
        tool: tool,
        audit_callback: ->(event) { audits << event }
      )

      data = assert_success!(response, "OpenAI production tool execution")
      assert_equal [ "seam-tool" ], tool.calls
      assert_match(/tool-ok/i, data.messages.first.output_text)

      call_event = audits.find { |event| event[:type] == :tool_calls }
      refute_nil call_event, "expected a tool-call audit event"
      call = call_event.fetch(:calls).find { |entry| entry[:function_name] == "echo_marker_seam" }
      refute_nil call, "expected the local echo_marker_seam tool call"

      result_event = audits.find { |event| event[:type] == :tool_result }
      refute_nil result_event, "expected a tool-result audit event"
      result = JSON.parse(result_event.fetch(:result))
      assert_equal "seam-tool", result["marker"]
      assert_equal true, result["executed"]
    end
  end

  test "OpenAI production seam returns strict structured synthetic categorizations" do
    require_live!(:openai)
    reference = explicit_reference!(:openai)

    LiveProviderHelper.with_live_network do
      response = provider.auto_categorize(
        transactions: [ { id: "synthetic-1", description: "Synthetic dining purchase" } ],
        user_categories: [ { name: "Dining" } ],
        model: reference
      )

      results = assert_success!(response, "OpenAI production structured categorization")
      assert_equal 1, results.size

      result = results.first
      assert_instance_of Provider::LlmConcept::AutoCategorization, result
      assert_equal "synthetic-1", result.transaction_id
      assert_equal "Dining", result.category_name
    end
  end

  test "explicit OpenAI and OpenCode Go references are selected independently at the production seam" do
    require_live!(:openai)
    require_live!(:opencode_go)

    openai_reference = explicit_reference!(:openai)
    go_reference = explicit_reference!(:opencode_go)

    assert openai_reference.start_with?("openai/")
    assert go_reference.start_with?("opencode_go/")
    refute_equal openai_reference, go_reference
    assert provider.supports_model?(openai_reference)
    assert provider.supports_model?(go_reference)
    assert_equal :openai, Provider::RubyLlm::Catalog.account_for(openai_reference)
    assert_equal :opencode_go, Provider::RubyLlm::Catalog.account_for(go_reference)

    compatibility = LiveProviderHelper.go_routing_compatibility

    if compatibility.blockers.any?
      skip(
        "OpenCode Go production-seam dual selection is blocked; no parity is claimed and " \
        "production routing is unchanged. Blockers: #{compatibility.blockers.join('; ')}"
      )
    end

    LiveProviderHelper.with_live_network do
      openai_response = provider.chat_response("Reply with exactly: dual-openai", model: openai_reference)
      go_response = provider.chat_response("Reply with exactly: dual-go", model: go_reference)

      openai_data = assert_success!(openai_response, "OpenAI production selection")
      go_data = assert_success!(go_response, "OpenCode Go production selection")

      assert_match(/dual-openai/i, openai_data.messages.first.output_text)
      assert_match(/dual-go/i, go_data.messages.first.output_text)
    end
  end
end
