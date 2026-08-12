class AddPlaidDomain < ActiveRecord::Migration[7.2]
  def change
    create_table :plaid_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :access_token
      t.string :plaid_id
      t.string :name
      t.string :next_cursor
      t.boolean :scheduled_for_deletion, default: false

      t.timestamps
    end

    create_table :plaid_accounts do |t|
      t.references :plaid_item, null: false, foreign_key: true, type: :uuid
      t.string :plaid_id
      t.string :plaid_type
      t.string :plaid_subtype
      t.decimal :current_balance, precision: 19, scale: 4
      t.decimal :available_balance, precision: 19, scale: 4
      t.string :currency
      t.string :name
      t.string :mask

      t.timestamps
    end

    create_table :syncs do |t|
      t.references :syncable, polymorphic: true, null: false, type: :uuid
      t.datetime :last_ran_at
      t.date :start_date
      t.string :status, default: "pending"
      t.string :error
      t.json :data

      t.timestamps
    end

    remove_column :families, :last_synced_at, :datetime
    add_column :families, :last_auto_synced_at, :datetime
    remove_column :accounts, :last_sync_date, :date
    remove_reference :accounts, :institution
    add_reference :accounts, :plaid_account, foreign_key: true

    add_column :account_entries, :plaid_id, :string
    add_column :accounts, :scheduled_for_deletion, :boolean, default: false

    drop_table :account_syncs do |t|
      t.timestamps
    end

    drop_table :institutions do |t|
      t.timestamps
    end
  end
end
