class FixPlaidItemPrimaryKeyToUuid < ActiveRecord::Migration[8.1]
  def up
    # Idempotent type guard: on databases where plaid_items was already created
    # with a uuid primary key (fresh builds from the corrected historical chain,
    # or a previously completed run), there is nothing to convert.
    return if column_type("plaid_items", "id") == "uuid"

    # Step 1: Preserve the old bigint ids and add the UUID column that will
    # become the new primary key. The gen_random_uuid() default is preserved
    # through the rename, matching the intended schema.
    add_column :plaid_items, :old_id, :bigint
    execute "UPDATE plaid_items SET old_id = id"

    add_column :plaid_items, :uuid_id, :uuid, default: -> { "gen_random_uuid()" }

    # Step 2: Swap the primary key. The plaid_accounts foreign key is removed
    # explicitly; the CASCADE would drop it anyway, but being explicit keeps its
    # restoration in Step 3 paired with the removal. if_exists tolerates a
    # database where the foreign key is already missing (pre-existing damage).
    remove_foreign_key :plaid_accounts, :plaid_items, if_exists: true
    execute "ALTER TABLE plaid_items DROP CONSTRAINT plaid_items_pkey CASCADE"
    remove_column :plaid_items, :id
    rename_column :plaid_items, :uuid_id, :id
    execute "ALTER TABLE plaid_items ADD PRIMARY KEY (id)"

    # Step 3: Remap plaid_accounts.plaid_item_id from the old bigint to the new
    # UUID, joining on the preserved old_id mapping. The index on the old column
    # is dropped with it and restored below.
    add_column :plaid_accounts, :uuid_plaid_item_id, :uuid

    execute <<~SQL
      UPDATE plaid_accounts
      SET uuid_plaid_item_id = plaid_items.id
      FROM plaid_items
      WHERE plaid_accounts.plaid_item_id = plaid_items.old_id
    SQL

    # Any plaid_item_id that failed to map would be silently nulled by
    # remove_column below, so fail fast instead. plaid_item_id is NOT NULL, so
    # this is a full-coverage check.
    assert_no_unmapped_plaid_item_references!

    remove_column :plaid_accounts, :plaid_item_id
    rename_column :plaid_accounts, :uuid_plaid_item_id, :plaid_item_id

    # Restore the original nullability, index and foreign key on the remapped
    # column. The rename preserves the NULL/NOT NULL flag of uuid_plaid_item_id
    # (nullable), so NOT NULL is re-applied explicitly.
    change_column_null :plaid_accounts, :plaid_item_id, false
    add_index :plaid_accounts, :plaid_item_id, if_not_exists: true
    add_foreign_key :plaid_accounts, :plaid_items, column: :plaid_item_id

    # Step 4: Remap PlaidItem logo attachments (active_storage record_id) from
    # the old bigint ids to the new UUIDs. The join compares as text so it is
    # agnostic to how the old ids are stored (uuid column vs. text ids).
    execute <<~SQL
      UPDATE active_storage_attachments
      SET record_id = plaid_items.id::text::uuid
      FROM plaid_items
      WHERE active_storage_attachments.record_type = 'PlaidItem'
        AND active_storage_attachments.record_id::text = plaid_items.old_id::text
    SQL

    # Refuse to leave any PlaidItem attachment pointing at a record that no
    # longer exists instead of silently keeping a dangling record_id.
    assert_no_unmapped_attachments! "PlaidItem"

    # plaid_items.old_id is intentionally kept: the deferred sync migration
    # remaps syncs.syncable_id for PlaidItem rows using this mapping.
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

    # Fail-fast guard used after the plaid_item_id remap UPDATE, before the old
    # bigint column is dropped. Any non-null plaid_item_id that failed to map
    # would be silently nulled by remove_column, so the migration aborts instead.
    def assert_no_unmapped_plaid_item_references!
      unmapped = select_value(<<~SQL)
        SELECT COUNT(*)
        FROM plaid_accounts
        WHERE plaid_item_id IS NOT NULL AND uuid_plaid_item_id IS NULL
      SQL

      return if unmapped.to_i.zero?

      raise ActiveRecord::IrreversibleMigration,
            "#{unmapped} plaid_accounts row(s) reference a plaid_item that no longer " \
            "exists; refusing to silently null their plaid_item_id. Investigate the " \
            "data before retrying."
    end

    # Fail-fast guard used after the attachment remap. Every PlaidItem attachment
    # must resolve to an existing plaid_item; rows left with an old (unmapped)
    # record_id would reference a record that no longer exists.
    def assert_no_unmapped_attachments!(record_type)
      unmapped = select_value(<<~SQL)
        SELECT COUNT(*)
        FROM active_storage_attachments
        WHERE record_type = '#{record_type}'
          AND record_id::text NOT IN (SELECT id::text FROM plaid_items)
      SQL

      return if unmapped.to_i.zero?

      raise ActiveRecord::IrreversibleMigration,
            "#{unmapped} #{record_type} attachment(s) reference a record that no " \
            "longer exists; refusing to leave dangling attachments. Investigate the " \
            "data before retrying."
    end

    def column_type(table, column)
      select_value(<<~SQL)
        SELECT data_type
        FROM information_schema.columns
        WHERE table_name = '#{table}'
          AND column_name = '#{column}'
      SQL
    end
end
