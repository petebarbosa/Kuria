module Mcp
  # Verifies Doorkeeper access tokens for the MCP resource server role.
  #
  # The verifier is read-only: it never touches financial data, writes audit
  # state, or updates the token. Claims are a snapshot for the request; callers
  # must revalidate the user and family on every request.
  class OauthTokenVerifier < MCP::Server::OAuth::TokenVerifier
    INVALID_TOKEN_ERROR = "The access token is invalid".freeze
    REQUIRED_SCOPE = "mcp".freeze

    def verify(raw_token)
      token = raw_token.to_s
      reject! if token.blank?

      record = Doorkeeper::AccessToken.by_token(token)
      reject! if record.nil? || !record.accessible?
      reject! if record.expires_at && record.expires_at <= Time.current
      reject! if record.application.nil?
      reject! if record.resource_owner_id.blank?

      user = User.find_by(id: record.resource_owner_id)
      reject! if user.nil?

      family = Family.find_by(id: user.family_id)
      reject! if family.nil?

      reject! unless self.class.scope_satisfied?(REQUIRED_SCOPE, record.scopes.to_a)

      application = record.application
      MCP::Server::OAuth::AccessToken.new(
        token: token,
        client_id: application.uid,
        scopes: record.scopes.to_a,
        expires_at: record.expires_at&.to_i,
        subject: user.id.to_s,
        claims: {
          "family_id" => family.id,
          "application_id" => application.id
        }
      )
    end

    # Exact membership, with the one deliberate hierarchy: read_write implies
    # read. It never implies mcp, and mcp never implies read.
    def self.scope_satisfied?(required_scope, granted_scopes)
      required = required_scope.to_s
      granted = Array(granted_scopes).map(&:to_s)

      granted.include?(required) || (required == "read" && granted.include?("read_write"))
    end

    private
      def reject!
        raise MCP::Server::OAuth::InvalidTokenError, INVALID_TOKEN_ERROR
      end
  end
end
