require "faraday/adapter/net_http"
require "json"

class Provider
  class RubyLlm < Provider
    # Strict Chat Completions streaming adapter (#16 finding 4).
    #
    # RubyLLM 2.1.1 tolerates malformed SSE events (it logs and drops them) and
    # never requires the terminal `[DONE]`, so a truncated or corrupt provider
    # stream can surface as a silently empty/short completion. Kuria installs
    # this adapter per RubyLLM context via `config.faraday_adapter` to validate
    # the raw bytes before RubyLLM forwards them, exactly once per request.
    #
    # Validation is request-local: Faraday connections (and therefore adapter
    # instances) are shared across RubyLLM contexts and threads, so all parser
    # state lives in the `call` closure, never in instance variables. Bytes are
    # validated and then forwarded unchanged; non-200 responses are delegated
    # untouched to RubyLLM 2.1.1's own status classifier. The original on_data
    # callback is always restored, and transport errors are never swallowed.
    class StreamingAdapter < Faraday::Adapter::NetHttp
      INVALID_STREAM_MESSAGE = "The model stream was malformed or incomplete.".freeze
      MALFORMED_TOOL_CALL_MESSAGE = "The model returned a structurally malformed tool call.".freeze
      MAX_JSON_BODY_BYTES = 1024 * 1024
      MAX_TOOL_CALL_IDENTIFIER_BYTES = 256
      MAX_TOOL_CALL_ARGUMENT_BYTES = 64 * 1024

      # Request-local recovery sink for raw streamed tool-call fragments. The
      # adapter instance/connection is shared across contexts and threads, so
      # the sink is threaded through isolated execution state only for the
      # duration of one request and never stored on the adapter.
      TOOL_CALL_COLLECTOR_KEY = :kuria_ruby_llm_tool_call_collector

      class << self
        def collect_tool_calls(collector)
          previous = Thread.current[TOOL_CALL_COLLECTOR_KEY]
          Thread.current[TOOL_CALL_COLLECTOR_KEY] = collector
          yield
        ensure
          Thread.current[TOOL_CALL_COLLECTOR_KEY] = previous
        end
      end

      # Raised from inside the adapter's on_data callback when a 200 response
      # is not a valid, complete Chat Completions stream. The message is fixed
      # and carries no provider payload; callers may retry the request safely
      # because nothing from the rejected stream was accepted.
      class InvalidStreamError < Faraday::Error
        def initialize
          super(INVALID_STREAM_MESSAGE)
        end
      end

      # Raised while observing a streamed tool-call envelope that cannot be
      # parsed safely (for example a non-object `function`). The error is fixed
      # and payload-free; the request-local collector still carries the
      # identifiable raw attempts for audit persistence. Raising before the
      # chunk reaches RubyLLM avoids its unclassified TypeError.
      class MalformedToolCallError < Faraday::Error
        def initialize
          super(MALFORMED_TOOL_CALL_MESSAGE)
        end
      end

      def call(env)
        callback = env.request.on_data
        return super unless callback

        state = new_stream_state
        env.request.on_data = lambda do |chunk, bytes, callback_env|
          if callback_env.status == 200
            begin
              validate_chunk(state, chunk, callback_env)
            rescue InvalidStreamError
              publish_recovered_tool_calls(state)
              raise
            end

            if state[:malformed_tool_call_envelope]
              publish_recovered_tool_calls(state)
              raise MalformedToolCallError
            end
          end
          callback.call(chunk, bytes, callback_env)
        end

        response = super
        ensure_complete_stream(state) if env.status == 200
        response
      ensure
        env.request.on_data = callback if callback
      end

      private

        def new_stream_state
          {
            parser: RubyLLM::Transport::EventStreamParser.new,
            format: nil,
            json_body: +"",
            json_parsed: false,
            done: false,
            completed: false,
            tool_calls: {},
            malformed_tool_call_envelope: false
          }
        end

        def validate_chunk(state, chunk, env)
          return if chunk.empty?

          state[:format] ||= stream_format(chunk, env)
          if state[:format] == :json
            validate_json_chunk(state, chunk)
          else
            validate_sse_chunk(state, chunk)
          end
        end

        def stream_format(chunk, env)
          headers = env.response_headers
          content_type = headers && headers["content-type"].to_s.downcase
          return :json if content_type.to_s.include?("json")

          chunk.lstrip.start_with?("{") ? :json : :sse
        end

        # A provider error event must carry the OpenAI-compatible error object;
        # valid payloads are forwarded with the bytes unchanged so RubyLLM's
        # normal status classifier still owns the error class/status.
        def validate_error_event_data(data)
          raise InvalidStreamError if data.empty?

          text = data.dup.force_encoding(Encoding::UTF_8)
          raise InvalidStreamError unless text.valid_encoding?

          parsed = JSON.parse(text)
          raise InvalidStreamError unless parsed.is_a?(Hash)
          raise InvalidStreamError unless parsed["error"].is_a?(Hash)
        rescue JSON::ParserError
          raise InvalidStreamError
        end

        def validate_json_chunk(state, chunk)
          state[:json_body] << chunk
          raise InvalidStreamError if state[:json_body].bytesize > MAX_JSON_BODY_BYTES

          parsed = JSON.parse(state[:json_body])
          raise InvalidStreamError unless parsed.is_a?(Hash)

          # A buffered error object is classified by RubyLLM itself; a buffered
          # non-error completion is not a stream and is rejected as incomplete.
          state[:json_buffered_error] = parsed.key?("error")
          raise InvalidStreamError unless state[:json_buffered_error] || parsed["choices"].is_a?(Array)

          state[:json_parsed] = true
        rescue JSON::ParserError
          # Incomplete JSON stays unparsed; ensure_complete_stream rejects it at
          # EOF if the body never becomes a valid object.
          nil
        end

        def validate_sse_chunk(state, chunk)
          state[:parser].feed(chunk) do |type, data|
            raise InvalidStreamError if state[:done]

            if data == "[DONE]"
              state[:done] = true
              next
            end

            if type.to_sym == :error
              validate_error_event_data(data)
              next
            end

            validate_event(state, parse_event(data))
          end
        end

        def parse_event(data)
          parsed = JSON.parse(data)
          raise InvalidStreamError unless parsed.is_a?(Hash)

          parsed
        rescue JSON::ParserError
          raise InvalidStreamError
        end

        def validate_event(state, parsed)
          # A data-level error object is also classified by RubyLLM.
          return if parsed.key?("error")

          usage = parsed["usage"]
          raise InvalidStreamError unless usage.nil? || usage.is_a?(Hash)

          choices = parsed["choices"]
          raise InvalidStreamError unless choices.is_a?(Array)

          if choices.empty?
            raise InvalidStreamError unless usage.is_a?(Hash)

            return
          end

          choices.each do |choice|
            raise InvalidStreamError unless choice.is_a?(Hash)

            finish_reason = choice["finish_reason"]
            raise InvalidStreamError unless finish_reason.nil? || finish_reason.is_a?(String)

            delta = choice["delta"]
            message = choice["message"]
            raise InvalidStreamError unless delta.nil? || delta.is_a?(Hash)
            raise InvalidStreamError unless message.nil? || message.is_a?(Hash)

            validate_payload(state, delta || message || {})
          end
        end

        def validate_payload(state, payload)
          content = payload["content"]
          raise InvalidStreamError unless content.nil? || content.is_a?(String)

          refusal = payload["refusal"]
          raise InvalidStreamError unless refusal.nil? || refusal.is_a?(String)

          role = payload["role"]
          raise InvalidStreamError unless role.nil? || role.is_a?(String)

          tool_calls = payload["tool_calls"]
          unless tool_calls.nil?
            raise InvalidStreamError unless tool_calls.is_a?(Array)
            raise InvalidStreamError unless tool_calls.all? { |call| call.is_a?(Hash) }

            collect_tool_calls(state, tool_calls)
          end

          state[:completed] ||= content_present?(content) || tool_calls.is_a?(Array) && tool_calls.any?
        end

        # Reconstructs the raw tool-call fragments for one response round. The
        # provider's arguments arrive as string fragments split arbitrarily
        # across events; ids/names may only arrive on a later fragment. Every
        # identifiable attempt is retained (index or id); only each call's
        # identifier and raw argument bytes are bounded. A recovered payload is
        # never logged or surfaced in user-facing errors.
        def collect_tool_calls(state, tool_calls)
          tool_calls.each do |call|
            key = tool_call_key(call)
            next if key.nil?

            entry = state[:tool_calls][key]
            if entry.nil?
              entry = state[:tool_calls][key] = { id: nil, name: nil, arguments: +"", truncated: false }
            end

            identifier = call["id"]
            if identifier.is_a?(String) && identifier.present? && identifier.bytesize <= MAX_TOOL_CALL_IDENTIFIER_BYTES
              entry[:id] = identifier if entry[:id].blank?
            end

            function = call["function"]
            if call.key?("function") && !function.nil? && !function.is_a?(Hash)
              mark_malformed_tool_call_envelope(state)
              append_raw_tool_call_payload(entry, function)
              next
            end
            next unless function.is_a?(Hash)

            name = function["name"]
            if function.key?("name") && !name.nil? && !name.is_a?(String)
              mark_malformed_tool_call_envelope(state)
              append_raw_tool_call_payload(entry, name)
            elsif name.is_a?(String) && name.present? && name.bytesize <= MAX_TOOL_CALL_IDENTIFIER_BYTES
              entry[:name] = name if entry[:name].blank?
            end

            arguments = function["arguments"]
            if function.key?("arguments") && !arguments.nil? && !arguments.is_a?(String)
              mark_malformed_tool_call_envelope(state)
              append_raw_tool_call_payload(entry, arguments)
            else
              append_tool_call_arguments(entry, arguments)
            end
          end
        end

        def mark_malformed_tool_call_envelope(state)
          state[:malformed_tool_call_envelope] = true
        end

        def append_raw_tool_call_payload(entry, payload)
          text = payload.is_a?(String) ? payload : JSON.generate(payload)
          append_tool_call_arguments(entry, text)
        rescue JSON::GeneratorError, TypeError
          append_tool_call_arguments(entry, payload.to_s)
        end

        def tool_call_key(call)
          index = call["index"]
          return "index:#{index}" if index.is_a?(Integer) || index.is_a?(String)

          identifier = call["id"]
          return "id:#{identifier}" if identifier.is_a?(String) && identifier.present?

          nil
        end

        def append_tool_call_arguments(entry, fragment)
          return unless fragment.is_a?(String)

          remaining = MAX_TOOL_CALL_ARGUMENT_BYTES - entry[:arguments].bytesize
          unless remaining.positive?
            entry[:truncated] = true
            return
          end

          if fragment.bytesize > remaining
            entry[:truncated] = true
            fragment = fragment.byteslice(0, remaining)
          end

          entry[:arguments] << fragment
        end

        def publish_recovered_tool_calls(state)
          collector = Thread.current[TOOL_CALL_COLLECTOR_KEY]
          return if collector.nil? || state[:tool_calls].empty?

          calls = state[:tool_calls].values.filter_map do |entry|
            next if entry[:id].blank? && entry[:name].blank? && entry[:arguments].empty?

            {
              id: entry[:id].presence,
              name: entry[:name].presence,
              raw_arguments: entry[:arguments],
              truncated: entry[:truncated]
            }
          end
          return if calls.empty?

          collector << { calls: calls }
        end

        def content_present?(content)
          content.is_a?(String) && !content.empty?
        end

        def ensure_complete_stream(state)
          begin
            if state[:format] == :json
              raise InvalidStreamError unless state[:json_parsed]

              # The buffered error path raises in RubyLLM before this point; a
              # buffered success on a streaming request never produced chunks.
              raise InvalidStreamError unless state[:json_buffered_error]
            else
              raise InvalidStreamError unless state[:done] && state[:completed]
            end
          rescue InvalidStreamError
            publish_recovered_tool_calls(state)
            raise
          end

          publish_recovered_tool_calls(state)
          raise MalformedToolCallError if state[:malformed_tool_call_envelope]
        end
    end
  end
end
