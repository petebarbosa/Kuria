class FixPolymorphicIdsToString < ActiveRecord::Migration[8.1]
  def up
    # Idempotent type guards: each polymorphic id column is converted to string
    # only while it is still bigint. Databases loaded from the corrected schema
    # already have these columns as string and are skipped entirely.
    fix_data_enrichments unless string_column?("data_enrichments", "enrichable_id")
    fix_import_mappings unless string_column?("import_mappings", "mappable_id")
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

    # data_enrichments.enrichable_id holds the primary keys of both bigint
    # targets (entries, transactions, merchants, ...) and uuid targets
    # (accounts). Only the uuid targets need to be stored as text; bigint
    # targets are converted with the same ::text cast.
    def fix_data_enrichments
      # Recreate the affected indexes around the type change instead of relying
      # on PostgreSQL silently rebuilding them.
      remove_index :data_enrichments,
                   name: "idx_on_enrichable_id_enrichable_type_source_attribu_5be5f63e08",
                   if_exists: true
      remove_index :data_enrichments,
                   name: "index_data_enrichments_on_enrichable",
                   if_exists: true

      quarantine_unrecoverable_account_enrichments!

      # The column stays NOT NULL: every surviving row resolves to a target.
      change_column :data_enrichments, :enrichable_id, :string, using: "enrichable_id::text"
      change_column_null :data_enrichments, :enrichable_id, false

      add_index :data_enrichments,
                [ :enrichable_id, :enrichable_type, :source, :attribute_name ],
                unique: true,
                name: "idx_on_enrichable_id_enrichable_type_source_attribu_5be5f63e08",
                if_not_exists: true
      add_index :data_enrichments,
                [ :enrichable_type, :enrichable_id ],
                name: "index_data_enrichments_on_enrichable",
                if_not_exists: true
    end

    # import_mappings.mappable_id mixes bigint targets (categories, tags) with
    # uuid targets (accounts). It stays nullable: creational mappings have no
    # target yet.
    def fix_import_mappings
      remove_index :import_mappings,
                   name: "index_import_mappings_on_mappable",
                   if_exists: true

      quarantine_unrecoverable_account_mappings!

      change_column :import_mappings, :mappable_id, :string, using: "mappable_id::text"

      add_index :import_mappings,
                [ :mappable_type, :mappable_id ],
                name: "index_import_mappings_on_mappable",
                if_not_exists: true
    end

    # Moves Account enrichment rows that no longer resolve to an existing
    # account into a quarantined snapshot before deleting them. Their ids are
    # the old bigint account ids, which cannot be recovered since accounts.old_id
    # was dropped. All other enrichable targets are preserved untouched. The
    # quarantine table is built with CREATE TABLE AS, so no constraints or index
    # names are copied from data_enrichments, and no ON CONFLICT clause is
    # needed because each row is moved exactly once.
    def quarantine_unrecoverable_account_enrichments!
      execute <<~SQL
        CREATE TABLE quarantined_data_enrichments AS
        SELECT data_enrichments.*, NOW() AS quarantined_at
        FROM data_enrichments
        WHERE enrichable_type = 'Account'
          AND enrichable_id::text NOT IN (SELECT id::text FROM accounts)
      SQL

      # The snapshot is keyed on the original enrichment id for easy reference.
      execute "ALTER TABLE quarantined_data_enrichments ADD PRIMARY KEY (id)"

      execute <<~SQL
        DELETE FROM data_enrichments de
        USING quarantined_data_enrichments q
        WHERE q.id = de.id
      SQL
    end

    # Moves Account import_mappings that no longer resolve to an existing
    # account into a quarantined snapshot before deleting them. Category, Tag
    # and AccountType mappings are preserved untouched.
    def quarantine_unrecoverable_account_mappings!
      execute <<~SQL
        CREATE TABLE quarantined_import_mappings AS
        SELECT import_mappings.*, NOW() AS quarantined_at
        FROM import_mappings
        WHERE mappable_type = 'Account'
          AND mappable_id::text NOT IN (SELECT id::text FROM accounts)
      SQL

      # The snapshot is keyed on the original mapping id for easy reference.
      execute "ALTER TABLE quarantined_import_mappings ADD PRIMARY KEY (id)"

      execute <<~SQL
        DELETE FROM import_mappings im
        USING quarantined_import_mappings q
        WHERE q.id = im.id
      SQL
    end

    def string_column?(table, column)
      %w[character varying text].include?(column_type(table, column))
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
