class AddOauthApplicationToMobileDevices < ActiveRecord::Migration[7.2]
  def change
    add_column :mobile_devices, :oauth_application_id, :bigint
    add_index :mobile_devices, :oauth_application_id
  end
end
