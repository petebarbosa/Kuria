class FixAccountUuidReferenceTypes < ActiveRecord::Migration[8.1]
  def up
    fix_account_reference :balances, on_delete: :cascade
    fix_account_reference :holdings

    # Restore the account_id indexes. if_not_exists keeps this safe on databases
    # where the historical migration already restored them.
    add_index :balances, :account_id, if_not_exists: true
    add_index :balances, [ :account_id, :date ], if_not_exists: true
    add_index :balances, [ :account_id, :date, :currency ], unique: true,
              name: "index_account_balances_on_account_id_date_currency_unique",
              if_not_exists: true

    add_index :holdings, :account_id, if_not_exists: true
    add_index :holdings, [ :account_id, :security_id, :date, :currency ], unique: true,
              name: "idx_on_account_id_security_id_date_currency_5323e39f8b",
              if_not_exists: true

    fix_imports_account_id
    validate_account_import_mappings!
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

    # balances/holdings.account_id must be a uuid foreign key to accounts.
    # Databases loaded from schema.rb record the historical UUID migration as
    # applied while leaving these columns bigint with no foreign key, because its
    # data remap never ran. When the column is already uuid, only the expected
    # nullability and foreign key are ensured; when it is still bigint, conversion
    # is refused as soon as the table holds any row, since the old bigint->UUID
    # mapping (accounts.old_id) no longer exists and cannot be recovered.
    def fix_account_reference(table, on_delete: nil)
      if column_type(table, "account_id") != "uuid"
        if table_has_rows?(table)
          raise ActiveRecord::IrreversibleMigration,
                "#{table}.account_id is bigint but #{table} has rows; the old " \
                "bigint->UUID mapping (accounts.old_id) no longer exists, so the " \
                "account_ids cannot be recovered safely. Investigate before retrying."
        end

        # The table is empty, so the USING expression is never evaluated. The
        # ::text hop is required: PostgreSQL has no direct bigint->uuid cast.
        change_column table, :account_id, :uuid, null: false, using: "account_id::text::uuid"
      end

      change_column_null table, :account_id, false

      return if foreign_key_exists?(table, :accounts, column: :account_id)

      add_foreign_key table, :accounts, column: :account_id, **{ on_delete: on_delete }.compact
    end

    # imports.account_id is a nullable string holding the account id as text.
    # NULLs are preserved; every non-null value must be a uuid that resolves to an
    # existing account before the column is converted to uuid. Stale text ids that
    # survived the skipped historical remap abort instead of being silently nulled.
    def fix_imports_account_id
      unmapped = select_value(<<~SQL)
        SELECT COUNT(*)
        FROM imports
        WHERE account_id IS NOT NULL
          AND account_id::text NOT IN (SELECT id::text FROM accounts)
      SQL

      if unmapped.to_i.positive?
        raise ActiveRecord::IrreversibleMigration,
              "#{unmapped} imports row(s) have an account_id that does not resolve " \
              "to an existing account; refusing to convert them to uuid. " \
              "Investigate before retrying."
      end

      # Nullability is preserved: imports.account_id stays nullable.
      change_column :imports, :account_id, :uuid, using: "account_id::uuid"
    end

    # Every Account import_mapping must point at an existing account id (stored as
    # text). Stale mappings that survived the skipped historical remap (old bigint
    # ids) abort rather than being left dangling.
    def validate_account_import_mappings!
      unmapped = select_value(<<~SQL)
        SELECT COUNT(*)
        FROM import_mappings
        WHERE mappable_type = 'Account'
          AND mappable_id IS NOT NULL
          AND mappable_id::text NOT IN (SELECT id::text FROM accounts)
      SQL

      return if unmapped.to_i.zero?

      raise ActiveRecord::IrreversibleMigration,
            "#{unmapped} Account import_mapping(s) have a mappable_id that does not " \
            "resolve to an existing account; refusing to leave stale mappings. " \
            "Investigate before retrying."
    end

    def column_type(table, column)
      select_value(<<~SQL)
        SELECT data_type
        FROM information_schema.columns
        WHERE table_name = '#{table}'
          AND column_name = '#{column}'
      SQL
    end

    def table_has_rows?(table)
      select_value("SELECT 1 FROM #{table} LIMIT 1").present?
    end
end
