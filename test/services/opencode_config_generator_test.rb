require "test_helper"
require "rake"

class OpencodeConfigGeneratorTest < ActiveSupport::TestCase
  setup do
    @generator = OpencodeConfigGenerator.new(
      mcp_url: "https://kuria.example.com/mcp",
      provider_keys: {
        "opencode" => "sk-test-opencode",
        "openai" => "sk-test-openai"
      }
    )
  end

  test "generates V2 remote MCP config with an env header placeholder" do
    config = @generator.generate
    server = config.dig("mcp", "servers", "maybe-finance")

    assert_equal "https://opencode.ai/config.json", config["$schema"]
    assert_equal "remote", server["type"]
    assert_equal "https://kuria.example.com/mcp", server["url"]
    assert_equal false, server["oauth"]
    assert_equal "Bearer {env:KURIA_MCP_ACCESS_TOKEN}", server.dig("headers", "Authorization")
  end

  test "removes deprecated V1 config fields" do
    config = @generator.generate
    server = config.dig("mcp", "servers", "maybe-finance")

    refute config.key?("provider")
    refute server.key?("enabled")
    refute server.key?("protocol")
    refute server.key?("codemode")
  end

  test "maps provider keys to V2 settings apiKey and excludes blanks" do
    config = @generator.generate

    assert_equal "sk-test-opencode", config.dig("providers", "opencode", "settings", "apiKey")
    assert_equal "sk-test-openai", config.dig("providers", "openai", "settings", "apiKey")

    blank_generator = OpencodeConfigGenerator.new(
      mcp_url: "https://kuria.example.com/mcp",
      provider_keys: {
        "opencode" => "sk-test-opencode",
        "openai" => "",
        "google" => nil
      }
    )
    blank_config = blank_generator.generate

    assert blank_config.dig("providers").key?("opencode")
    refute blank_config.dig("providers").key?("openai")
    refute blank_config.dig("providers").key?("google")
  end

  test "never embeds a raw MCP token or legacy setting token" do
    with_env("KURIA_MCP_ACCESS_TOKEN" => "synthetic-kuria-token") do
      Setting.stubs(:mcp_auth_token).returns("synthetic-legacy-token")
      json = @generator.to_json

      refute_includes json, "synthetic-kuria-token"
      refute_includes json, "synthetic-legacy-token"
      assert_includes json, "Bearer {env:KURIA_MCP_ACCESS_TOKEN}"
    end
  end

  test "to_json returns valid V2 JSON" do
    parsed = JSON.parse(@generator.to_json)

    assert_equal "https://opencode.ai/config.json", parsed["$schema"]
    assert_equal "remote", parsed.dig("mcp", "servers", "maybe-finance", "type")
  end

  test "write_to writes a private file with only the env placeholder" do
    with_env("KURIA_MCP_ACCESS_TOKEN" => "synthetic-kuria-token") do
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".opencode", "opencode.json")

        @generator.write_to(path)

        assert File.exist?(path)
        assert_equal 0o600, File.stat(path).mode & 0o777
        contents = File.read(path)
        refute_includes contents, "synthetic-kuria-token"
        assert_includes contents, "Bearer {env:KURIA_MCP_ACCESS_TOKEN}"
        assert_equal "remote", JSON.parse(contents).dig("mcp", "servers", "maybe-finance", "type")
      end
    end
  end

  test "from_settings uses OPENCODE_MCP_HOST and PORT without reading the legacy token" do
    with_env("OPENCODE_MCP_HOST" => "kuria.example.com", "PORT" => "3000") do
      Setting.expects(:mcp_auth_token).never

      config = OpencodeConfigGenerator.from_settings.generate

      assert_equal "http://kuria.example.com:3000/mcp", config.dig("mcp", "servers", "maybe-finance", "url")
      assert_equal({}, config.fetch("providers"))
    end
  end

  test "from_settings falls back to host.docker.internal and port 3000" do
    with_env("OPENCODE_MCP_HOST" => nil, "PORT" => nil) do
      Setting.expects(:mcp_auth_token).never

      config = OpencodeConfigGenerator.from_settings.generate

      assert_equal "http://host.docker.internal:3000/mcp", config.dig("mcp", "servers", "maybe-finance", "url")
    end
  end

  test "rake task reports the V2 URL and empty providers without writing the repo config" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("opencode:config:generate")

    generator = mock("opencode config generator")
    generator.expects(:write_to).with(Rails.root.join(".opencode", "opencode.json"))
    generator.stubs(:generate).returns({
      "mcp" => {
        "servers" => {
          "maybe-finance" => { "url" => "http://kuria.example.com:3000/mcp" }
        }
      },
      "providers" => {}
    })
    OpencodeConfigGenerator.stubs(:from_settings).returns(generator)

    out, _err = capture_io do
      Rake::Task["opencode:config:generate"].reenable
      Rake::Task["opencode:config:generate"].invoke
    end

    assert_match(%r{MCP URL: http://kuria\.example\.com:3000/mcp}, out)
    assert_match(/Providers: \(none\)/, out)
    refute_match(/Bearer/, out)
  end

  test "gitignore ignores the generated config but not OpenCode skills" do
    root = Rails.root.to_s
    git = [ "git", "-C", root, "-c", "core.excludesFile=/dev/null" ]

    assert system(*git, "check-ignore", "-q", ".opencode/opencode.json")
    refute system(*git, "check-ignore", "-q", ".opencode/skills/example/SKILL.md")
  end

  private
    def with_env(values)
      originals = values.keys.to_h { |key| [ key, ENV[key] ] }
      values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }

      yield
    ensure
      originals.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end
end
