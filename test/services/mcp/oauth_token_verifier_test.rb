require "test_helper"

class Mcp::OauthTokenVerifierTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @application = Doorkeeper::Application.create!(
      name: "MCP OAuth test client",
      redirect_uri: "https://example.com/mcp/callback",
      scopes: "read read_write mcp"
    )
    @verifier = Mcp::OauthTokenVerifier.new
  end

  test "verifies a real hashed access token and exposes bound identity and scopes" do
    token = create_token(scopes: "mcp", expires_in: 1.hour)
    raw = token.plaintext_token
    token.reload

    assert_not_equal raw, token.token

    before_attributes = Doorkeeper::AccessToken.find(token.id).attributes
    result = @verifier.verify(raw)
    after_attributes = Doorkeeper::AccessToken.find(token.id).attributes

    assert_equal before_attributes, after_attributes

    assert_instance_of MCP::Server::OAuth::AccessToken, result
    assert_equal raw, result.token
    assert_equal @application.uid, result.client_id
    assert_equal [ "mcp" ], result.scopes
    assert_equal token.expires_at.to_i, result.expires_at
    assert_equal @user.id.to_s, result.subject
    assert_equal(
      { "family_id" => @user.family_id, "application_id" => @application.id },
      result.claims
    )

    refute_includes result.inspect, raw
    refute_includes result.to_h.inspect, raw
  end

  test "rejects a token at the exact expiry boundary" do
    travel_to Time.zone.local(2026, 1, 1, 12, 0, 0) do
      token = create_token(scopes: "mcp", expires_in: 0)
      raw = token.plaintext_token

      error = assert_raises(MCP::Server::OAuth::InvalidTokenError) do
        @verifier.verify(raw)
      end

      assert_equal "The access token is invalid", error.message
      refute_includes error.message, raw
    end
  end

  test "rejects blank and unknown raw tokens with a generic message" do
    [ nil, "", "   ", "unknown-#{SecureRandom.hex(8)}" ].each do |raw|
      assert_invalid(raw)
    end
  end

  test "rejects expired and revoked tokens" do
    expired = create_token(scopes: "mcp", expires_in: 1.hour, created_at: 2.hours.ago)
    revoked = create_token(scopes: "mcp", expires_in: 1.hour)
    revoked_raw = revoked.plaintext_token
    revoked.revoke

    assert_invalid(expired.plaintext_token)
    assert_invalid(revoked_raw)
  end

  test "rejects client credentials tokens without a resource owner" do
    token = create_token(scopes: "mcp", expires_in: 1.hour, resource_owner_id: nil)

    assert_invalid(token.plaintext_token)
  end

  test "rejects tokens whose resource owner no longer exists" do
    token = create_token(
      scopes: "mcp",
      expires_in: 1.hour,
      resource_owner_id: SecureRandom.uuid
    )

    assert_invalid(token.plaintext_token)
  end

  test "rejects tokens whose family no longer exists" do
    token = create_token(scopes: "mcp", expires_in: 1.hour)
    Family.stubs(:find_by).with(id: @user.family_id).returns(nil)

    assert_invalid(token.plaintext_token)
  end

  test "rejects tokens whose client application is unavailable" do
    token = create_token(scopes: "mcp", expires_in: 1.hour)
    raw = token.plaintext_token
    record = Doorkeeper::AccessToken.by_token(raw)
    record.stubs(:application).returns(nil)
    Doorkeeper::AccessToken.stubs(:by_token).with(raw).returns(record)

    assert_invalid(raw)
  end

  test "rejects tokens removed together with their client application" do
    token = create_token(scopes: "mcp", expires_in: 1.hour)
    raw = token.plaintext_token
    token.destroy!

    assert_invalid(raw)

    other = create_token(scopes: "mcp", expires_in: 1.hour)
    other_raw = other.plaintext_token
    @application.destroy!

    assert_invalid(other_raw)
  end

  test "requires the exact mcp scope for read and read_write tokens" do
    read = create_token(scopes: "read", expires_in: 1.hour)
    read_write = create_token(scopes: "read_write", expires_in: 1.hour)
    no_scopes = create_token(scopes: nil, expires_in: 1.hour)

    assert_invalid(read.plaintext_token)
    assert_invalid(read_write.plaintext_token)
    assert_invalid(no_scopes.plaintext_token)
  end

  test "scope matcher isolates read_write to read and never grants mcp" do
    verifier = Mcp::OauthTokenVerifier

    assert verifier.scope_satisfied?("read", [ "read" ])
    assert verifier.scope_satisfied?("read", [ "read_write" ])
    assert verifier.scope_satisfied?("mcp", [ "mcp" ])

    refute verifier.scope_satisfied?("mcp", [ "read" ])
    refute verifier.scope_satisfied?("mcp", [ "read_write" ])
    refute verifier.scope_satisfied?("read", [ "mcp" ])
    refute verifier.scope_satisfied?("read", [])
    refute verifier.scope_satisfied?("write", [ "read_write" ])
  end

  test "does not accept the global MCP setting token as a fallback" do
    raw = "global-mcp-#{SecureRandom.hex(8)}"
    Setting.stubs(:mcp_auth_token).returns(raw)

    assert_invalid(raw)
  end

  private
    def assert_invalid(raw)
      error = assert_raises(MCP::Server::OAuth::InvalidTokenError) do
        @verifier.verify(raw)
      end

      assert_equal "The access token is invalid", error.message
      refute_includes error.message, raw.to_s if raw.present?
      error
    end

    def create_token(scopes:, **attributes)
      Doorkeeper::AccessToken.create!(
        application: @application,
        resource_owner_id: @user.id,
        scopes: scopes,
        **attributes
      )
    end
end
