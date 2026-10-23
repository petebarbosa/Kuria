class Provider
  class RubyLlm < Provider
    # Fail-closed normalization and validation for RubyLLM structured-output
    # responses.
    #
    # RubyLLM 2.1 leaves Chat Completions structured output as JSON text in
    # `Message#content` and exposes the parsed Hash publicly via
    # `Message#parsed`. Messages that already carry a Hash (existing fake/testing
    # seams) are accepted as-is; malformed JSON and provider refusals stay
    # non-Hash and fail closed. Only a Hash can carry a valid structured
    # result, so anything else raises Provider::RubyLlm::Error and surfaces as a
    # failed Provider::Response through the caller's `with_provider_response`.
    #
    # Every returned entry is additionally validated for required fields, value
    # types, and permitted (enum) values before a successful response is built:
    # a malformed entry fails the whole response closed rather than letting a
    # caller act on partially corrupted enrichment. Error messages name the
    # capability and field only — never the raw model content — so no response
    # data or secret leaks through the error path.
    module StructuredOutput
      NULL_SENTINEL = "null".freeze

      module_function

      def content_hash!(final_message, capability)
        content = final_message.respond_to?(:content) ? final_message.content : nil

        # RubyLLM 2.1 leaves Chat Completions structured output as JSON text in
        # `content`; `Message#parsed` is the public accessor for the Hash.
        # Malformed JSON raises there and keeps the String below, so the
        # existing fail-closed message is preserved.
        if content.is_a?(String) && final_message.respond_to?(:parsed)
          begin
            parsed = final_message.parsed
          rescue JSON::ParserError
            parsed = nil
          end

          content = parsed if parsed.is_a?(Hash)
        end

        return content if content.is_a?(Hash)

        description = content.nil? ? "an empty response or provider refusal" : "a #{content.class.name}"

        raise Error, "RubyLLM #{capability} did not return structured JSON (got #{description}); failing closed."
      end

      # Normalize the recognised explicit-null sentinel "null" to nil. Only the
      # sentinel is rewritten; every other value is returned untouched for the
      # caller to validate.
      def nullable(value)
        value == NULL_SENTINEL ? nil : value
      end

      def array_of_hashes!(content, key, capability)
        entries = content[key]

        unless entries.is_a?(Array) && entries.all? { |entry| entry.is_a?(Hash) }
          raise Error, "RubyLLM #{capability} response is missing a '#{key}' array of objects; failing closed."
        end

        entries
      end

      # A required transaction id: present, and a non-blank String (the schema
      # types transaction_id as a String). Integer or any other type fails
      # closed — there is no numeric coercion. Membership in the request's
      # input ids is deliberately NOT enforced — the whole-result contract
      # tolerates a well-formed entry for an unknown/extra String id (the
      # domain ignores it), a policy covered by tests.
      def required_id!(entry, key, capability)
        unless entry.key?(key)
          raise Error, "RubyLLM #{capability} returned an entry missing '#{key}'; failing closed."
        end

        value = entry[key]
        return value if value.is_a?(String) && value.present?

        raise Error, "RubyLLM #{capability} returned an entry with an invalid '#{key}' type; failing closed."
      end

      # A required key whose value must be one of `permitted` (an admitted enum,
      # which may include NULL_SENTINEL). Used where the schema restricts a
      # value to a known set, e.g. category names.
      def required_member!(entry, key, permitted, capability)
        unless entry.key?(key)
          raise Error, "RubyLLM #{capability} returned an entry missing '#{key}'; failing closed."
        end

        value = entry[key]
        return value if permitted.include?(value)

        raise Error, "RubyLLM #{capability} returned an entry with an invalid '#{key}' value; failing closed."
      end

      # A required key whose value must be a String, a real JSON null, or the
      # explicit-null sentinel. Other types (numbers, collections) fail closed.
      def nullable_string!(entry, key, capability)
        unless entry.key?(key)
          raise Error, "RubyLLM #{capability} returned an entry missing '#{key}'; failing closed."
        end

        value = entry[key]
        return nil if value.nil? || value == NULL_SENTINEL
        return value if value.is_a?(String)

        raise Error, "RubyLLM #{capability} returned an entry with an invalid '#{key}' type; failing closed."
      end

      # A required, non-null String value.
      def required_string!(content, key, capability)
        unless content.key?(key)
          raise Error, "RubyLLM #{capability} response is missing '#{key}'; failing closed."
        end

        value = content[key]
        return value if value.is_a?(String)

        raise Error, "RubyLLM #{capability} response has an invalid '#{key}' type; failing closed."
      end

      # A suggested merchant id: explicit null (or the sentinel) means "no
      # suggestion"; otherwise the id must be a String that is one of the
      # request's admitted merchant ids (the schema types merchant_id as
      # string|null). Integers and other types fail closed — no
      # numeric-to-string coercion. Returns the admitted String id or nil.
      def suggestion_merchant_id!(content, permitted_ids, capability)
        unless content.key?("merchant_id")
          raise Error, "RubyLLM #{capability} response is missing 'merchant_id'; failing closed."
        end

        value = content["merchant_id"]
        return nil if value.nil? || value == NULL_SENTINEL
        return value if value.is_a?(String) && permitted_ids.include?(value)

        raise Error, "RubyLLM #{capability} response has an invalid 'merchant_id'; failing closed."
      end

      # A suggested confidence: a real finite Numeric within [0.0, 1.0]. Strings,
      # nil, booleans, NaN/Infinity (JSON "1e309" parses to Float::INFINITY), and
      # out-of-range values all fail closed — no default and no string coercion.
      def suggestion_confidence!(content, capability)
        unless content.key?("confidence")
          raise Error, "RubyLLM #{capability} response is missing 'confidence'; failing closed."
        end

        value = content["confidence"]
        return value if value.is_a?(Numeric) && value.finite? && value >= 0 && value <= 1

        raise Error, "RubyLLM #{capability} response has an invalid 'confidence'; failing closed."
      end

      # Reject a response where the same transaction id appears more than once:
      # that is ambiguous and could let a caller apply conflicting enrichment.
      def reject_duplicate_ids!(ids, capability)
        duplicated = ids.map(&:to_s).tally.any? { |_id, count| count > 1 }
        return unless duplicated

        raise Error, "RubyLLM #{capability} returned duplicate transaction ids; failing closed."
      end

      # --- adapter-boundary id type normalization ---------------------------
      #
      # The domain stores and correlates bigint (Integer) ids while the provider
      # schemas type their id fields as Strings. The adapter canonicalizes ids
      # to Strings on the way out and restores the original input id type on the
      # way back, so no domain caller has to change and no malformed provider
      # value is ever coerced.

      # Canonical String forms of an input id set, for outbound schema enums.
      # Returns a new array; the caller's collection is never mutated.
      def string_ids(ids)
        ids.map(&:to_s)
      end

      # New copies of the given record hashes with only the :id value
      # canonicalized to a String, for outbound prompts. The caller's hashes are
      # never mutated.
      def stringify_record_ids(records)
        records.map { |record| record.merge(id: record[:id].to_s) }
      end

      # Map a provider-returned String id back to the original input id
      # value/type when it matches an input id by String form, so domain
      # equality against the original (e.g. Integer bigint) id still holds. A
      # well-formed id that matches no input (unknown/extra) is returned
      # unchanged (String), non-String values pass through untouched, and no
      # type coercion is performed (malformed provider Integers are rejected by
      # the String validators before reaching here).
      def original_id_for(returned, input_ids)
        return returned unless returned.is_a?(String)

        input_ids.find { |id| id.to_s == returned } || returned
      end
    end
  end
end
