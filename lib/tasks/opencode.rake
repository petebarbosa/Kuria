namespace :opencode do
  namespace :config do
    desc "Generate opencode.json for hybrid dev setup"
    task generate: :environment do
      config = OpencodeConfigGenerator.from_settings
      output_path = Rails.root.join(".opencode", "opencode.json")
      generated = config.generate
      provider_names = generated.fetch("providers", {}).keys

      config.write_to(output_path)

      puts "OpenCode config written to: #{output_path}"
      puts "MCP URL: #{generated.dig('mcp', 'servers', 'maybe-finance', 'url')}"
      puts "Providers: #{provider_names.join(', ').presence || '(none)'}"
      puts "Client env: KURIA_MCP_ACCESS_TOKEN must be an OAuth token with the mcp scope (and read or read_write)."
    end
  end
end
