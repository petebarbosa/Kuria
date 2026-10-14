class AddEnrichmentModelToFamilies < ActiveRecord::Migration[8.1]
  def change
    # Canonical, family-scoped reference (e.g. "openai/gpt-5-nano" or
    # "opencode_go/kimi-k3") for the model used by transaction enrichment
    # (auto-categorization and merchant detection/suggestion). NULL means the
    # family has not chosen a model; there is no deployment or environment
    # default. Credentials are never stored here.
    add_column :families, :enrichment_model, :string
  end
end
