# Dynamic settings the user can change within the app (helpful for self-hosting)
class Setting < RailsSettings::Base
  cache_prefix { "v1" }

  field :synth_api_key, type: :string, default: ENV["SYNTH_API_KEY"]
  field :mcp_auth_token, type: :string, default: ENV["MCP_AUTH_TOKEN"]

  field :freecrypto_api_key, type: :string, default: ENV["FREECRYPTO_API_KEY"]
  field :require_invite_for_signup, type: :boolean, default: false
  field :require_email_confirmation, type: :boolean, default: ENV.fetch("REQUIRE_EMAIL_CONFIRMATION", "true") == "true"
end
