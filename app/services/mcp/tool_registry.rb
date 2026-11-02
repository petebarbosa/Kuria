class Mcp::ToolRegistry
  READ_TOOL_CLASSES = [
    McpTools::GetAccounts,
    McpTools::GetTransactions,
    McpTools::GetBalanceSheet,
    McpTools::GetIncomeStatement
  ].freeze

  WRITE_TOOL_CLASSES = [
    McpTools::CreateTransaction,
    McpTools::UpdateTransaction,
    McpTools::CreateOrUpdateBudget,
    McpTools::CreateOrUpdateBudgetCategory,
    McpTools::ConfirmAction
  ].freeze

  AUTHENTICATION_ERROR = "Unauthorized".freeze
  WRITE_SCOPE_ERROR = "This action requires the read_write scope.".freeze

  class << self
    def tools
      READ_TOOL_CLASSES.map { |klass| native_tool(klass) } +
        WRITE_TOOL_CLASSES.map { |klass| legacy_tool(klass) }
    end

    private
      def native_tool(native_class)
        handler = method(:call_native)

        MCP::Tool.define(
          name: native_class.tool_name,
          description: native_class.description,
          input_schema: client_schema(native_class.input_schema_value.to_h)
        ) do |server_context: nil, **params|
          handler.call(native_class, server_context, params)
        end
      end

      def legacy_tool(legacy_class)
        handler = method(:call_legacy)

        MCP::Tool.define(
          name: legacy_class.tool_name,
          description: legacy_class.tool_description,
          input_schema: client_schema(legacy_class.tool_input_schema)
        ) do |server_context: nil, **params|
          handler.call(legacy_class, server_context, params)
        end
      end

      def call_native(native_class, server_context, params)
        identity = identity_for(server_context)
        return authentication_error if identity.nil?

        _user, family = identity
        native_class.call(
          **params.symbolize_keys.except(:family_id),
          family_id: family.id,
          server_context: server_context
        )
      end

      def call_legacy(legacy_class, server_context, params)
        identity = identity_for(server_context)
        return authentication_error if identity.nil?

        auth_info = server_context.auth_info
        return write_scope_error unless auth_info.scopes.include?("read_write")

        user, family = identity
        arguments = params.deep_stringify_keys.except("user_id", "idempotency_key")

        result = if legacy_class == McpTools::ConfirmAction
          legacy_class.execute(arguments, user: user, family: family)
        else
          legacy_class.execute(arguments.merge("family_id" => family.id), user: user)
        end

        MCP::Tool::Response.new(result[:content], error: result[:isError] == true)
      end

      def identity_for(server_context)
        auth_info = server_context.auth_info if server_context.respond_to?(:auth_info)
        return unless auth_info.is_a?(MCP::Server::OAuth::AccessToken)

        user = User.find_by(id: auth_info.subject)
        return if user.nil?

        family = Family.find_by(id: user.family_id)
        return if family.nil?
        return unless auth_info.claims["family_id"] == family.id

        [ user, family ]
      end

      def client_schema(source)
        schema = JSON.parse(JSON.generate(source))
        properties = schema["properties"] || {}
        %w[family_id user_id idempotency_key].each { |key| properties.delete(key) }

        schema["properties"] = properties
        schema["required"] = Array(schema["required"]) - %w[family_id user_id idempotency_key]
        schema["additionalProperties"] = false
        schema
      end

      def authentication_error
        MCP::Tool::Response.new([ { type: "text", text: AUTHENTICATION_ERROR } ], error: true)
      end

      def write_scope_error
        MCP::Tool::Response.new([ { type: "text", text: WRITE_SCOPE_ERROR } ], error: true)
      end
  end
end
