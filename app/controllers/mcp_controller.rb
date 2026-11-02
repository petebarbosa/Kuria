class McpController < ActionController::API
  def handle
    status, headers, body = transport.handle_request(Rack::Request.new(request.env))

    response.status = status
    headers.each { |name, value| response.set_header(name, value) }
    self.response_body = body
  end

  private
    def transport
      MCP::Server::Transports::StreamableHTTPTransport.new(
        server,
        stateless: true,
        enable_json_response: true,
        serve_subscriptions_listen: false,
        token_verifier: Mcp::OauthTokenVerifier.new,
        required_scopes: %w[mcp read],
        scope_matcher: Mcp::OauthTokenVerifier.method(:scope_satisfied?),
        allowed_hosts: allowed_hosts
      )
    end

    def server
      MCP::Server.new(
        name: "maybe-finance",
        version: "1.0.0",
        tools: Mcp::ToolRegistry.tools
      )
    end

    def allowed_hosts
      mail_options = Rails.application.config.action_mailer.default_url_options || {}
      mail_host = mail_options[:host] || mail_options["host"]

      [ ENV["APP_DOMAIN"], mail_host ].compact_blank.uniq
    end
end
