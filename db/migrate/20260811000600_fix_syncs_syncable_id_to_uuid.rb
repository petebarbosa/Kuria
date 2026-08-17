class FixSyncsSyncableIdToUuid < ActiveRecord::Migration[8.1]
  def up
    # Idempotent type guard: on databases where syncs.syncable_id was already
    # converted to uuid (fresh builds from the corrected schema, or a previously
    # completed run), there is nothing to convert and plaid_items.old_id is
    # already gone.
    return if column_type("syncs", "syncable_id") == "uuid"

    # Dependency guard: the Plaid migration (fix_plaid_item_primary_key_to_uuid)
    # intentionally keeps plaid_items.old_id so PlaidItem syncs can be remapped
    # here. If it is missing while syncable_id is still bigint, the chain is out
    # of order and those bigint ids cannot be recovered.
    unless column_exists?(:plaid_items, :old_id) && column_type("plaid_items", "id") == "uuid"
      raise ActiveRecord::IrreversibleMigration,
            "syncs.syncable_id is bigint but plaid_items.old_id is not available; " \
            "the Plaid UUID migration must run first so PlaidItem syncs can be remapped."
    end

    # Step 1: Quarantine every sync that can no longer resolve to a live
    # syncable, plus its recursive descendants, before deleting them. Account
    # and Family syncs store ids from before those tables became uuid (or ids
    # that were never storable), and the accounts.old_id mapping has already
    # been dropped, so they cannot be remapped. PlaidItem syncs whose old id no
    # longer resolves to a plaid_item are equally unrecoverable.
    quarantine_unrecoverable_syncs!

    # Step 2: Add the uuid column and remap PlaidItem syncs through the retained
    # old_id mapping. Every remaining sync must resolve afterwards.
    add_column :syncs, :syncable_uuid, :uuid

    execute <<~SQL
      UPDATE syncs
      SET syncable_uuid = plaid_items.id
      FROM plaid_items
      WHERE syncs.syncable_type = 'PlaidItem'
        AND syncs.syncable_id = plaid_items.old_id
    SQL

    assert_all_syncs_mapped!

    # Step 3: Swap the columns, preserving the NOT NULL flag and the syncable
    # index. The index is dropped explicitly and recreated after the rename.
    remove_index :syncs, name: "index_syncs_on_syncable", if_exists: true
    change_column_null :syncs, :syncable_uuid, false
    remove_column :syncs, :syncable_id
    rename_column :syncs, :syncable_uuid, :syncable_id
    add_index :syncs, [ :syncable_type, :syncable_id ], name: "index_syncs_on_syncable", if_not_exists: true

    # Step 4: Nothing else references the retained mapping now; drop it.
    remove_column :plaid_items, :old_id
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

    # Moves every unrecoverable sync (and its recursive descendants) out of
    # syncs into a quarantined_syncs snapshot before deleting them. The
    # quarantine table is built with CREATE TABLE AS, so none of syncs' indexes,
    # primary key or constraints are copied (their names would collide in the
    # same schema), and rows are moved 1:1 so no ON CONFLICT clause is needed.
    def quarantine_unrecoverable_syncs!
      # The recursive set is computed once into a session-scoped temp table so
      # the DELETE below never needs a giant IN list.
      execute <<~SQL
        CREATE TEMP TABLE syncs_to_quarantine AS
        WITH RECURSIVE unrecoverable_syncs AS (
          SELECT syncs.id
          FROM syncs
          WHERE syncs.syncable_type IN ('Account', 'Family')
             OR (syncs.syncable_type = 'PlaidItem'
                 AND NOT EXISTS (
                   SELECT 1 FROM plaid_items
                   WHERE plaid_items.old_id = syncs.syncable_id
                 ))
          UNION
          SELECT children.id
          FROM syncs children
          JOIN unrecoverable_syncs parent ON children.parent_id = parent.id
        )
        SELECT id FROM unrecoverable_syncs
      SQL

      execute <<~SQL
        CREATE TABLE quarantined_syncs AS
        SELECT syncs.*, NOW() AS quarantined_at
        FROM syncs
        JOIN syncs_to_quarantine ON syncs_to_quarantine.id = syncs.id
      SQL

      # The snapshot is keyed on the original sync id for easy reference.
      execute "ALTER TABLE quarantined_syncs ADD PRIMARY KEY (id)"

      # One statement removes the whole set, so the self-referencing parent_id
      # foreign key is never violated: every descendant of a deleted sync is
      # deleted in the same statement.
      execute <<~SQL
        DELETE FROM syncs
        WHERE id IN (SELECT id FROM syncs_to_quarantine)
      SQL
    end

    # Fail-fast guard used after the PlaidItem remap. Every remaining sync must
    # have resolved to a real syncable; a NULL syncable_uuid means the quarantine
    # missed a row that cannot be mapped.
    def assert_all_syncs_mapped!
      unmapped = select_value(<<~SQL)
        SELECT COUNT(*)
        FROM syncs
        WHERE syncable_uuid IS NULL
      SQL

      return if unmapped.to_i.zero?

      raise ActiveRecord::IrreversibleMigration,
            "#{unmapped} sync(s) reference a syncable that no longer exists; " \
            "refusing to leave dangling syncable_ids. Investigate the data before retrying."
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
