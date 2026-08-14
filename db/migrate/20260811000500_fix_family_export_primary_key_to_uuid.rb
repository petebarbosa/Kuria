class FixFamilyExportPrimaryKeyToUuid < ActiveRecord::Migration[8.1]
  def up
    # Idempotent type guard: on databases where family_exports was already
    # created with a uuid primary key (fresh builds from the corrected
    # historical chain, or a previously completed run), there is nothing to
    # convert.
    return if column_type("family_exports", "id") == "uuid"

    # Step 1: Preserve the old bigint ids and add the UUID column that will
    # become the new primary key. The gen_random_uuid() default is preserved
    # through the rename, matching the intended schema.
    add_column :family_exports, :old_id, :bigint
    execute "UPDATE family_exports SET old_id = id"

    add_column :family_exports, :uuid_id, :uuid, default: -> { "gen_random_uuid()" }

    # Step 2: Swap the primary key. No table has a foreign key to
    # family_exports, so the CASCADE drops nothing here; it is kept for parity
    # with the plaid_items conversion and to fail loudly on any future
    # unanticipated dependent.
    execute "ALTER TABLE family_exports DROP CONSTRAINT family_exports_pkey CASCADE"
    remove_column :family_exports, :id
    rename_column :family_exports, :uuid_id, :id
    execute "ALTER TABLE family_exports ADD PRIMARY KEY (id)"

    # Step 3: Remap export_file attachments (active_storage record_id) from the
    # old bigint ids to the new UUIDs. The join compares as text so it is
    # agnostic to how the old ids are stored (uuid column vs. text ids).
    execute <<~SQL
      UPDATE active_storage_attachments
      SET record_id = family_exports.id::text::uuid
      FROM family_exports
      WHERE active_storage_attachments.record_type = 'FamilyExport'
        AND active_storage_attachments.record_id::text = family_exports.old_id::text
    SQL

    # Refuse to drop the old_id mapping while any FamilyExport attachment still
    # references a record that no longer exists.
    assert_no_unmapped_attachments!

    # Step 4: Every dependent (attachments) has been remapped and validated, so
    # the old_id mapping is no longer needed.
    remove_column :family_exports, :old_id
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

    # Fail-fast guard used after the attachment remap. Every FamilyExport
    # attachment must resolve to an existing family_export; rows left with an old
    # (unmapped) record_id would reference a record that no longer exists once
    # old_id is dropped.
    def assert_no_unmapped_attachments!
      unmapped = select_value(<<~SQL)
        SELECT COUNT(*)
        FROM active_storage_attachments
        WHERE record_type = 'FamilyExport'
          AND record_id::text NOT IN (SELECT id::text FROM family_exports)
      SQL

      return if unmapped.to_i.zero?

      raise ActiveRecord::IrreversibleMigration,
            "#{unmapped} FamilyExport attachment(s) reference a record that no " \
            "longer exists; refusing to drop the old_id mapping. Investigate the " \
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
