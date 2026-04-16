class OpencodeConfigGenerator
  def initialize(mcp_url:, mcp_auth_token:, provider_keys: {})
    @mcp_url = mcp_url
    @mcp_auth_token = mcp_auth_token
    @provider_keys = provider_keys
  end

  def generate
    {
      "provider" => build_providers,
      "mcp" => build_mcp_config
    }
  end

  def to_json
    JSON.pretty_generate(generate)
  end

  def write_to(path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, to_json)
  end

  def self.from_settings
    mcp_host = ENV.fetch("OPENCODE_MCP_HOST", "host.docker.internal")
    mcp_port = ENV.fetch("PORT", "3000")

    new(
      mcp_url: "http://#{mcp_host}:#{mcp_port}/mcp",
      mcp_auth_token: Setting.mcp_auth_token,
    )
  end

  private

    attr_reader :mcp_url, :mcp_auth_token, :provider_keys

    def build_providers
      provider_keys
        .select { |_name, key| key.present? }
        .transform_values { |key| { "api_key" => key } }
    end

    def build_mcp_config
      {
        "maybe-finance" => {
          "type" => "remote",
          "url" => mcp_url,
          "headers" => {
            "Authorization" => "Bearer #{mcp_auth_token}"
          }
        }
      }
    end
end
