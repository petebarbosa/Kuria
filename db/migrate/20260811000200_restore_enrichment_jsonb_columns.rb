class RestoreEnrichmentJsonbColumns < ActiveRecord::Migration[8.1]
  def up
    # json -> jsonb is lossless: json values are valid JSON by type definition.
    change_column :data_enrichments, :value, :jsonb, using: "value::jsonb"
    change_column :data_enrichments, :metadata, :jsonb, using: "metadata::jsonb"

    %w[
      accounts
      credit_cards
      cryptos
      depositories
      entries
      investments
      loans
      other_assets
      other_liabilities
      properties
      trades
      transactions
      valuations
      vehicles
    ].each do |table|
      # Re-specifying the existing default keeps it intact through the type change.
      change_column table, :locked_attributes, :jsonb, using: "locked_attributes::jsonb", default: {}
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
