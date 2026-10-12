class AddAiModelSelection < ActiveRecord::Migration[8.1]
  def change
    add_column :chats, :ai_model, :string
  end
end
