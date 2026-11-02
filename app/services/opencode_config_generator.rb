class OpencodeConfigGenerator
  MCP_ACCESS_TOKEN_HEADER = "Bearer {env:KURIA_MCP_ACCESS_TOKEN}".freeze

  def initialize(mcp_url:, provider_keys: {})
    @mcp_url = mcp_url
    @provider_keys = provider_keys
  end

  def generate
    {
      "$schema" => "https://opencode.ai/config.json",
      "providers" => build_providers,
      "mcp" => build_mcp_config
    }
  end

  def to_json
    JSON.pretty_generate(generate)
  end

  def write_to(path)
    FileUtils.mkdir_p(File.dirname(path))
    File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
      file.write(to_json)
    end
    File.chmod(0o600, path)
  end

  def self.from_settings
    mcp_host = ENV.fetch("OPENCODE_MCP_HOST", "host.docker.internal")
    mcp_port = ENV.fetch("PORT", "3000")

    new(mcp_url: "http://#{mcp_host}:#{mcp_port}/mcp")
  end

  private

    attr_reader :mcp_url, :provider_keys

    def build_providers
      provider_keys
        .select { |_name, key| key.present? }
        .transform_values { |key| { "settings" => { "apiKey" => key } } }
    end

    def build_mcp_config
      {
        "servers" => {
          "maybe-finance" => {
            "type" => "remote",
            "url" => mcp_url,
            "oauth" => false,
            "headers" => {
              "Authorization" => MCP_ACCESS_TOKEN_HEADER
            }
          }
        }
      }
    end
end
