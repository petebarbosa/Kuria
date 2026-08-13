class FixEntriesEntryableIdTypeAndConstraints < ActiveRecord::Migration[8.1]
  def up
    # entryable_id stores the primary keys of the entryable records (transactions,
    # valuations, trades) as text. Convert it back to bigint so joins compare on
    # matching types instead of casting every id. Nullability is preserved.
    change_column :entries, :entryable_id, :bigint, using: "entryable_id::bigint"

    # Restore the NOT NULL constraint on account_id lost during the UUID migration.
    change_column_null :entries, :account_id, false

    # Restore the indexes on account_id dropped when the accounts primary key changed.
    add_index :entries, :account_id, if_not_exists: true
    add_index :entries, [ :account_id, :date ], if_not_exists: true
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
