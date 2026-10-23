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
      MAX_JSON_BODY_BYTES = 1024 * 1024

      # Raised from inside the adapter's on_data callback when a 200 response
      # is not a valid, complete Chat Completions stream. The message is fixed
      # and carries no provider payload; callers may retry the request safely
      # because nothing from the rejected stream was accepted.
      class InvalidStreamError < Faraday::Error
        def initialize
          super(INVALID_STREAM_MESSAGE)
        end
      end

      def call(env)
        callback = env.request.on_data
        return super unless callback

        state = new_stream_state
        env.request.on_data = lambda do |chunk, bytes, callback_env|
          validate_chunk(state, chunk, callback_env) if callback_env.status == 200
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
            completed: false
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
          end

          state[:completed] ||= content_present?(content) || tool_calls.is_a?(Array) && tool_calls.any?
        end

        def content_present?(content)
          content.is_a?(String) && !content.empty?
        end

        def ensure_complete_stream(state)
          if state[:format] == :json
            raise InvalidStreamError unless state[:json_parsed]

            # The buffered error path raises in RubyLLM before this point; a
            # buffered success on a streaming request never produced chunks.
            raise InvalidStreamError unless state[:json_buffered_error]
          else
            raise InvalidStreamError unless state[:done] && state[:completed]
          end
        end
    end
  end
end
