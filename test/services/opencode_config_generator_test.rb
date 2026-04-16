require "test_helper"

class OpencodeConfigGeneratorTest < ActiveSupport::TestCase
  setup do
    @generator = OpencodeConfigGenerator.new(
      mcp_url: "http://web:3000/mcp",
      mcp_auth_token: "test-token-123",
      provider_keys: {
        "opencode" => "sk-ant-test",
        "openai" => "sk-test"
      }
    )
  end

  test "generates valid config hash" do
    config = @generator.generate

    assert config.is_a?(Hash)
    assert config.key?("provider")
    assert config.key?("mcp")
  end

  test "includes provider API keys" do
    config = @generator.generate

    assert_equal "sk-ant-test", config.dig("provider", "opencode", "api_key")
    assert_equal "sk-test", config.dig("provider", "openai", "api_key")
  end

  test "includes MCP server config" do
    config = @generator.generate

    mcp_config = config.dig("mcp", "maybe-finance")
    assert_equal "remote", mcp_config["type"]
    assert_equal "http://web:3000/mcp", mcp_config["url"]
    assert_equal "Bearer test-token-123", mcp_config.dig("headers", "Authorization")
  end

  test "excludes providers with blank keys" do
    generator = OpencodeConfigGenerator.new(
      mcp_url: "http://web:3000/mcp",
      mcp_auth_token: "test-token",
      provider_keys: {
        "opencode" => "sk-ant-test",
        "openai" => "",
        "google" => nil
      }
    )

    config = generator.generate

    assert config.dig("provider").key?("opencode")
    refute config.dig("provider").key?("openai")
    refute config.dig("provider").key?("google")
  end

  test "to_json returns valid JSON string" do
    json = @generator.to_json

    assert json.is_a?(String)
    parsed = JSON.parse(json)
    assert parsed.key?("provider")
  end

  test "write_to writes config to file" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "opencode.json")
      @generator.write_to(path)

      assert File.exist?(path)
      parsed = JSON.parse(File.read(path))
      assert_equal "sk-ant-test", parsed.dig("provider", "opencode", "api_key")
    end
  end

  test "generates hybrid MCP URL when OPENCODE_MCP_HOST is set" do
    ENV["OPENCODE_MCP_HOST"] = "host.docker.internal"
    ENV["PORT"] = "3000"

    generator = OpencodeConfigGenerator.from_settings
    config = generator.generate

    assert_equal "http://host.docker.internal:3000/mcp", config.dig("mcp", "maybe-finance", "url")
  ensure
    ENV.delete("OPENCODE_MCP_HOST")
    ENV.delete("PORT")
  end

  test "generates valid config without any provider keys" do
    generator = OpencodeConfigGenerator.new(
      mcp_url: "http://host.docker.internal:3000/mcp",
      mcp_auth_token: "test-token",
      provider_keys: {}
    )

    config = generator.generate

    assert config.key?("provider")
    assert config.key?("mcp")
    assert_equal "http://host.docker.internal:3000/mcp", config.dig("mcp", "maybe-finance", "url")
    assert config.dig("provider").empty?
  end
end
