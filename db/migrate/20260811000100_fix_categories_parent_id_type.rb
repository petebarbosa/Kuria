class FixCategoriesParentIdType < ActiveRecord::Migration[8.1]
  def up
    # parent_id stores the bigint primary keys of parent categories as text.
    # Convert it back to bigint, treating empty strings as NULL.
    change_column :categories, :parent_id, :bigint, using: "NULLIF(parent_id::text, '')::bigint"
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
