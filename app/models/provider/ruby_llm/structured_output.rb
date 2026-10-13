class Provider
  class RubyLlm < Provider
    # Fail-closed normalization for RubyLLM structured-output responses.
    #
    # RubyLLM parses model JSON into a Hash with string keys when the response
    # is valid JSON, leaves malformed JSON as a String, and yields nil for a
    # provider refusal (the SDK drops refusal payloads). Only a Hash can carry
    # a valid structured result, so anything else raises Provider::RubyLlm::Error
    # and surfaces as a failed Provider::Response through the caller's
    # `with_provider_response`. A malformed or refused response is never
    # presented as a fabricated empty success.
    module StructuredOutput
      module_function

      def content_hash!(final_message, capability)
        content = final_message.respond_to?(:content) ? final_message.content : nil
        return content if content.is_a?(Hash)

        description = content.nil? ? "an empty response or provider refusal" : "a #{content.class.name}"

        raise Error, "RubyLLM #{capability} did not return structured JSON (got #{description}); failing closed."
      end

      # The model contract encodes explicit nulls as the string "null" (an enum
      # member), so both a real JSON null and "null" normalize to nil.
      def nullable(value)
        value == "null" ? nil : value
      end

      def array_of_hashes!(content, key, capability)
        entries = content[key]

        unless entries.is_a?(Array) && entries.all? { |entry| entry.is_a?(Hash) }
          raise Error, "RubyLLM #{capability} response is missing a '#{key}' array of objects; failing closed."
        end

        entries
      end
    end
  end
end
