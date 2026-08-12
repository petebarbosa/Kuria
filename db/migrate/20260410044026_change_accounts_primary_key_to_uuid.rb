class ChangeAccountsPrimaryKeyToUuid < ActiveRecord::Migration[8.1]
  def up
    # Step 1: Store old bigint IDs and create UUID mapping
    add_column :accounts, :old_id, :bigint
    execute "UPDATE accounts SET old_id = id"

    # Step 2: Create a new UUID column in accounts
    add_column :accounts, :uuid_id, :uuid, default: -> { "gen_random_uuid()" }

    # Step 3: Remove the entries foreign key explicitly. The CASCADE below drops
    # the remaining foreign keys (balances, holdings) referencing the old primary key.
    remove_foreign_key :entries, :accounts

    # Step 4: Change accounts primary key to UUID.
    # CASCADE drops dependent foreign keys (entries, balances, holdings), NOT indexes.
    execute "ALTER TABLE accounts DROP CONSTRAINT accounts_pkey CASCADE"
    remove_column :accounts, :id
    rename_column :accounts, :uuid_id, :id
    execute "ALTER TABLE accounts ADD PRIMARY KEY (id)"

    # Step 5: Remap entries.account_id from old bigint to new UUID.
    # Indexes on account_id are dropped with the column and restored in Step 11.
    add_column :entries, :uuid_account_id, :uuid

    execute <<~SQL
      UPDATE entries#{' '}
      SET uuid_account_id = accounts.id#{' '}
      FROM accounts#{' '}
      WHERE entries.account_id = accounts.old_id
    SQL

    remove_column :entries, :account_id
    rename_column :entries, :uuid_account_id, :account_id

    # Step 6: Remap balances.account_id from old bigint to new UUID.
    add_column :balances, :uuid_account_id, :uuid

    execute <<~SQL
      UPDATE balances#{' '}
      SET uuid_account_id = accounts.id#{' '}
      FROM accounts#{' '}
      WHERE balances.account_id = accounts.old_id
    SQL

    remove_column :balances, :account_id
    rename_column :balances, :uuid_account_id, :account_id

    # Step 7: Remap holdings.account_id from old bigint to new UUID.
    add_column :holdings, :uuid_account_id, :uuid

    execute <<~SQL
      UPDATE holdings#{' '}
      SET uuid_account_id = accounts.id#{' '}
      FROM accounts#{' '}
      WHERE holdings.account_id = accounts.old_id
    SQL

    remove_column :holdings, :account_id
    rename_column :holdings, :uuid_account_id, :account_id

    # Step 8: Remap imports.account_id (optional string column) from old bigint
    # text to the new UUID.
    add_column :imports, :uuid_account_id, :uuid

    execute <<~SQL
      UPDATE imports#{' '}
      SET uuid_account_id = accounts.id#{' '}
      FROM accounts#{' '}
      WHERE imports.account_id = accounts.old_id::text
    SQL

    remove_column :imports, :account_id
    rename_column :imports, :uuid_account_id, :account_id

    # Step 9: Remap Account rows in import_mappings (mappable_id is a string) from
    # old bigint text to the new UUID text. Category/Tag/Merchant rows keep their
    # non-account string ids.
    execute <<~SQL
      UPDATE import_mappings#{' '}
      SET mappable_id = accounts.id::text#{' '}
      FROM accounts#{' '}
      WHERE import_mappings.mappable_type = 'Account'
        AND import_mappings.mappable_id = accounts.old_id::text
    SQL

    # Step 10: Restore original nullability. imports.account_id stays nullable.
    change_column_null :entries, :account_id, false
    change_column_null :balances, :account_id, false
    change_column_null :holdings, :account_id, false

    # Step 11: Restore indexes on the remapped account_id columns. if_not_exists
    # guards against any index already present from the historical chain.
    add_index :entries, :account_id, if_not_exists: true
    add_index :entries, [ :account_id, :date ], if_not_exists: true

    add_index :balances, :account_id, if_not_exists: true
    add_index :balances, [ :account_id, :date ], if_not_exists: true
    add_index :balances, [ :account_id, :date, :currency ], unique: true, name: "index_account_balances_on_account_id_date_currency_unique", if_not_exists: true

    add_index :holdings, :account_id, if_not_exists: true
    add_index :holdings, [ :account_id, :security_id, :date, :currency ], unique: true, name: "idx_on_account_id_security_id_date_currency_5323e39f8b", if_not_exists: true

    # Step 12: Restore foreign keys to accounts (dropped by the primary key CASCADE).
    add_foreign_key :entries, :accounts, column: :account_id
    add_foreign_key :balances, :accounts, column: :account_id, on_delete: :cascade
    add_foreign_key :holdings, :accounts, column: :account_id

    # Step 13: Drop the old id mapping last, after every table has been remapped.
    remove_column :accounts, :old_id
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
