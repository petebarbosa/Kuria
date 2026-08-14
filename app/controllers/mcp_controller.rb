class McpController < ApplicationController
  skip_before_action :verify_authenticity_token
  skip_authentication
  before_action :authenticate_mcp_client

  LEGACY_TOOL_CLASSES = [
    McpTools::ConfirmAction,
    McpTools::CreateTransaction,
    McpTools::UpdateTransaction,
    McpTools::CreateOrUpdateBudget,
    McpTools::CreateOrUpdateBudgetCategory,
    McpTools::UpsertExchangeRates
  ].freeze

  def handle
    server = MCP::Server.new(
      name: "maybe-finance",
      version: "1.0.0",
      tools: mcp_tools
    )

    result = server.handle_json(request.body.read)
    render json: result
  end

  private

    # Legacy tools expose tool_name/tool_description/tool_input_schema/execute and
    # are not MCP::Tool subclasses, so wrap each one as an official MCP::Tool class
    # at registration time.
    def mcp_tools
      [
        McpTools::GetTransactions,
        McpTools::GetAccounts,
        McpTools::GetBalanceSheet,
        McpTools::GetIncomeStatement,
        *LEGACY_TOOL_CLASSES.map { |legacy_class| mcp_tool_wrapper(legacy_class) }
      ]
    end

    def mcp_tool_wrapper(legacy_class)
      MCP::Tool.define(
        name: legacy_class.tool_name,
        description: legacy_class.tool_description,
        input_schema: legacy_class.tool_input_schema
      ) do |server_context: nil, **params|
        result = legacy_class.execute(params.deep_stringify_keys)
        MCP::Tool::Response.new(result[:content])
      end
    end

    def authenticate_mcp_client
      token = extract_bearer_token
      expected = Setting.mcp_auth_token

      unless expected.present? && token.present? && ActiveSupport::SecurityUtils.secure_compare(token, expected)
        render json: { error: "Unauthorized" }, status: :unauthorized
      end
    end

    def extract_bearer_token
      header = request.headers["Authorization"]
      return nil unless header&.start_with?("Bearer ")
      header.sub("Bearer ", "")
    end
end
