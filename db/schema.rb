# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_08_11_000200) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pgcrypto"

  create_table "accounts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.bigint "accountable_id"
    t.string "accountable_type"
    t.decimal "balance", precision: 19, scale: 4
    t.decimal "cash_balance", precision: 19, scale: 4, default: "0.0"
    t.virtual "classification", type: :string, as: "\nCASE\n    WHEN ((accountable_type)::text = ANY ((ARRAY['Loan'::character varying, 'CreditCard'::character varying, 'OtherLiability'::character varying])::text[])) THEN 'liability'::text\n    ELSE 'asset'::text\nEND", stored: true
    t.datetime "created_at", null: false
    t.string "currency"
    t.uuid "family_id", null: false
    t.bigint "import_id"
    t.jsonb "locked_attributes", default: {}
    t.string "name"
    t.bigint "plaid_account_id"
    t.string "status", default: "active"
    t.string "subtype"
    t.datetime "updated_at", null: false
    t.index ["accountable_id", "accountable_type"], name: "index_accounts_on_accountable_id_and_accountable_type"
    t.index ["accountable_type"], name: "index_accounts_on_accountable_type"
    t.index ["currency"], name: "index_accounts_on_currency"
    t.index ["family_id", "accountable_type"], name: "index_accounts_on_family_id_and_accountable_type"
    t.index ["family_id", "status"], name: "index_accounts_on_family_id_and_status"
    t.index ["family_id"], name: "index_accounts_on_family_id"
    t.index ["import_id"], name: "index_accounts_on_import_id"
    t.index ["plaid_account_id"], name: "index_accounts_on_plaid_account_id"
    t.index ["status"], name: "index_accounts_on_status"
  end

  create_table "active_storage_attachments", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.uuid "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "addresses", force: :cascade do |t|
    t.bigint "addressable_id"
    t.string "addressable_type"
    t.string "country"
    t.string "county"
    t.datetime "created_at", null: false
    t.string "line1"
    t.string "line2"
    t.string "locality"
    t.integer "postal_code"
    t.string "region"
    t.datetime "updated_at", null: false
    t.index ["addressable_type", "addressable_id"], name: "index_addresses_on_addressable"
  end

  create_table "api_keys", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "display_key", null: false
    t.datetime "expires_at"
    t.datetime "last_used_at"
    t.string "name"
    t.datetime "revoked_at"
    t.json "scopes"
    t.string "source", default: "web"
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["display_key"], name: "index_api_keys_on_display_key", unique: true
    t.index ["revoked_at"], name: "index_api_keys_on_revoked_at"
    t.index ["user_id", "source"], name: "index_api_keys_on_user_id_and_source"
    t.index ["user_id"], name: "index_api_keys_on_user_id"
  end

  create_table "balances", force: :cascade do |t|
    t.uuid "account_id", null: false
    t.decimal "balance", precision: 19, scale: 4, null: false
    t.decimal "cash_adjustments", precision: 19, scale: 4, default: "0.0", null: false
    t.decimal "cash_balance", precision: 19, scale: 4, default: "0.0"
    t.decimal "cash_inflows", precision: 19, scale: 4, default: "0.0", null: false
    t.decimal "cash_outflows", precision: 19, scale: 4, default: "0.0", null: false
    t.datetime "created_at", null: false
    t.string "currency", default: "USD", null: false
    t.date "date", null: false
    t.virtual "end_balance", type: :decimal, precision: 19, scale: 4, as: "(((start_cash_balance + ((cash_inflows - cash_outflows) * (flows_factor)::numeric)) + cash_adjustments) + (((start_non_cash_balance + ((non_cash_inflows - non_cash_outflows) * (flows_factor)::numeric)) + net_market_flows) + non_cash_adjustments))", stored: true
    t.virtual "end_cash_balance", type: :decimal, precision: 19, scale: 4, as: "((start_cash_balance + ((cash_inflows - cash_outflows) * (flows_factor)::numeric)) + cash_adjustments)", stored: true
    t.virtual "end_non_cash_balance", type: :decimal, precision: 19, scale: 4, as: "(((start_non_cash_balance + ((non_cash_inflows - non_cash_outflows) * (flows_factor)::numeric)) + net_market_flows) + non_cash_adjustments)", stored: true
    t.integer "flows_factor", default: 1, null: false
    t.decimal "net_market_flows", precision: 19, scale: 4, default: "0.0", null: false
    t.decimal "non_cash_adjustments", precision: 19, scale: 4, default: "0.0", null: false
    t.decimal "non_cash_inflows", precision: 19, scale: 4, default: "0.0", null: false
    t.decimal "non_cash_outflows", precision: 19, scale: 4, default: "0.0", null: false
    t.virtual "start_balance", type: :decimal, precision: 19, scale: 4, as: "(start_cash_balance + start_non_cash_balance)", stored: true
    t.decimal "start_cash_balance", precision: 19, scale: 4, default: "0.0", null: false
    t.decimal "start_non_cash_balance", precision: 19, scale: 4, default: "0.0", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "date", "currency"], name: "index_account_balances_on_account_id_date_currency_unique", unique: true
    t.index ["account_id", "date"], name: "index_balances_on_account_id_and_date"
    t.index ["account_id"], name: "index_balances_on_account_id"
  end

  create_table "budget_categories", force: :cascade do |t|
    t.bigint "budget_id", null: false
    t.decimal "budgeted_spending", precision: 19, scale: 4, null: false
    t.bigint "category_id", null: false
    t.datetime "created_at", null: false
    t.string "currency", null: false
    t.datetime "updated_at", null: false
    t.index ["budget_id", "category_id"], name: "index_budget_categories_on_budget_id_and_category_id", unique: true
    t.index ["budget_id"], name: "index_budget_categories_on_budget_id"
    t.index ["category_id"], name: "index_budget_categories_on_category_id"
  end

  create_table "budgets", force: :cascade do |t|
    t.decimal "budgeted_spending", precision: 19, scale: 4
    t.datetime "created_at", null: false
    t.string "currency", null: false
    t.date "end_date", null: false
    t.decimal "expected_income", precision: 19, scale: 4
    t.uuid "family_id", null: false
    t.date "start_date", null: false
    t.datetime "updated_at", null: false
    t.index ["family_id", "start_date", "end_date"], name: "index_budgets_on_family_id_and_start_date_and_end_date", unique: true
    t.index ["family_id"], name: "index_budgets_on_family_id"
  end

  create_table "categories", force: :cascade do |t|
    t.string "classification", default: "expense", null: false
    t.string "color", default: "#6172F3", null: false
    t.datetime "created_at", null: false
    t.uuid "family_id", null: false
    t.string "lucide_icon", default: "shapes", null: false
    t.string "name", null: false
    t.bigint "parent_id"
    t.datetime "updated_at", null: false
    t.index ["family_id"], name: "index_categories_on_family_id"
  end

  create_table "chats", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.json "error"
    t.string "instructions"
    t.string "latest_assistant_response_id"
    t.string "opencode_session_id"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["user_id"], name: "index_chats_on_user_id"
  end

  create_table "credit_cards", force: :cascade do |t|
    t.decimal "annual_fee", precision: 10, scale: 2
    t.decimal "apr", precision: 10, scale: 2
    t.decimal "available_credit", precision: 10, scale: 2
    t.datetime "created_at", null: false
    t.date "expiration_date"
    t.jsonb "locked_attributes", default: {}
    t.decimal "minimum_payment", precision: 10, scale: 2
    t.datetime "updated_at", null: false
  end

  create_table "cryptos", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "locked_attributes", default: {}
    t.datetime "updated_at", null: false
  end

  create_table "data_enrichments", force: :cascade do |t|
    t.string "attribute_name"
    t.datetime "created_at", null: false
    t.bigint "enrichable_id", null: false
    t.string "enrichable_type", null: false
    t.jsonb "metadata"
    t.string "source"
    t.datetime "updated_at", null: false
    t.jsonb "value"
    t.index ["enrichable_id", "enrichable_type", "source", "attribute_name"], name: "idx_on_enrichable_id_enrichable_type_source_attribu_5be5f63e08", unique: true
    t.index ["enrichable_type", "enrichable_id"], name: "index_data_enrichments_on_enrichable"
  end

  create_table "depositories", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "locked_attributes", default: {}
    t.datetime "updated_at", null: false
  end

  create_table "entries", force: :cascade do |t|
    t.uuid "account_id", null: false
    t.decimal "amount", precision: 19, scale: 4, null: false
    t.datetime "created_at", null: false
    t.string "currency"
    t.date "date"
    t.bigint "entryable_id"
    t.string "entryable_type"
    t.boolean "excluded", default: false
    t.bigint "import_id"
    t.jsonb "locked_attributes", default: {}
    t.string "name", null: false
    t.text "notes"
    t.string "plaid_id"
    t.datetime "updated_at", null: false
    t.index "lower((name)::text)", name: "index_entries_on_lower_name"
    t.index ["account_id", "date"], name: "index_entries_on_account_id_and_date"
    t.index ["account_id"], name: "index_entries_on_account_id"
    t.index ["date"], name: "index_entries_on_date"
    t.index ["entryable_type"], name: "index_entries_on_entryable_type"
    t.index ["import_id"], name: "index_entries_on_import_id"
  end

  create_table "exchange_rates", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.date "date", null: false
    t.string "from_currency", null: false
    t.decimal "rate", null: false
    t.string "to_currency", null: false
    t.datetime "updated_at", null: false
    t.index ["from_currency", "to_currency", "date"], name: "index_exchange_rates_on_base_converted_date_unique", unique: true
    t.index ["from_currency"], name: "index_exchange_rates_on_from_currency"
    t.index ["to_currency"], name: "index_exchange_rates_on_to_currency"
  end

  create_table "families", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "auto_sync_on_login", default: true, null: false
    t.string "country", default: "US"
    t.datetime "created_at", null: false
    t.string "currency", default: "USD"
    t.boolean "data_enrichment_enabled", default: false
    t.string "date_format", default: "%m-%d-%Y"
    t.boolean "early_access", default: false
    t.datetime "latest_sync_activity_at", default: -> { "CURRENT_TIMESTAMP" }
    t.datetime "latest_sync_completed_at", default: -> { "CURRENT_TIMESTAMP" }
    t.string "locale", default: "en"
    t.string "name"
    t.string "stripe_customer_id"
    t.string "timezone"
    t.datetime "updated_at", null: false
  end

  create_table "family_exports", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "family_id", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["family_id"], name: "index_family_exports_on_family_id"
  end

  create_table "holdings", force: :cascade do |t|
    t.uuid "account_id", null: false
    t.decimal "amount", precision: 19, scale: 4, null: false
    t.datetime "created_at", null: false
    t.string "currency", null: false
    t.date "date", null: false
    t.decimal "price", precision: 19, scale: 4, null: false
    t.decimal "qty", precision: 19, scale: 4, null: false
    t.bigint "security_id", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "security_id", "date", "currency"], name: "idx_on_account_id_security_id_date_currency_5323e39f8b", unique: true
    t.index ["account_id"], name: "index_holdings_on_account_id"
    t.index ["security_id"], name: "index_holdings_on_security_id"
  end

  create_table "impersonation_session_logs", force: :cascade do |t|
    t.string "action"
    t.string "controller"
    t.datetime "created_at", null: false
    t.bigint "impersonation_session_id", null: false
    t.string "ip_address"
    t.string "method"
    t.text "path"
    t.datetime "updated_at", null: false
    t.text "user_agent"
    t.index ["impersonation_session_id"], name: "index_impersonation_session_logs_on_impersonation_session_id"
  end

  create_table "impersonation_sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "impersonated_id", null: false
    t.uuid "impersonator_id", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["impersonated_id"], name: "index_impersonation_sessions_on_impersonated_id"
    t.index ["impersonator_id"], name: "index_impersonation_sessions_on_impersonator_id"
  end

  create_table "import_mappings", force: :cascade do |t|
    t.boolean "create_when_empty", default: true
    t.datetime "created_at", null: false
    t.bigint "import_id", null: false
    t.string "key"
    t.string "mappable_id"
    t.string "mappable_type"
    t.string "type", null: false
    t.datetime "updated_at", null: false
    t.string "value"
    t.index ["import_id"], name: "index_import_mappings_on_import_id"
    t.index ["mappable_type", "mappable_id"], name: "index_import_mappings_on_mappable"
  end

  create_table "import_rows", force: :cascade do |t|
    t.string "account"
    t.string "amount"
    t.string "category"
    t.datetime "created_at", null: false
    t.string "currency"
    t.string "date"
    t.string "entity_type"
    t.string "exchange_operating_mic"
    t.bigint "import_id", null: false
    t.string "name"
    t.text "notes"
    t.string "price"
    t.string "qty"
    t.string "tags"
    t.string "ticker"
    t.datetime "updated_at", null: false
    t.index ["import_id"], name: "index_import_rows_on_import_id"
  end

  create_table "imports", force: :cascade do |t|
    t.string "account_col_label"
    t.uuid "account_id"
    t.string "amount_col_label"
    t.string "amount_type_inflow_value"
    t.string "amount_type_strategy", default: "signed_amount"
    t.string "category_col_label"
    t.string "col_sep", default: ","
    t.json "column_mappings"
    t.datetime "created_at", null: false
    t.string "currency_col_label"
    t.string "date_col_label"
    t.string "date_format", default: "%m/%d/%Y"
    t.string "entity_type_col_label"
    t.string "error"
    t.string "exchange_operating_mic_col_label"
    t.uuid "family_id", null: false
    t.string "name_col_label"
    t.string "normalized_csv_str"
    t.string "notes_col_label"
    t.string "number_format"
    t.string "price_col_label"
    t.string "qty_col_label"
    t.string "raw_file_str"
    t.string "signage_convention", default: "inflows_positive"
    t.string "status"
    t.string "tags_col_label"
    t.string "ticker_col_label"
    t.string "type", null: false
    t.datetime "updated_at", null: false
    t.index ["family_id"], name: "index_imports_on_family_id"
  end

  create_table "investments", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "locked_attributes", default: {}
    t.datetime "updated_at", null: false
  end

  create_table "invitations", force: :cascade do |t|
    t.datetime "accepted_at"
    t.datetime "created_at", null: false
    t.string "email"
    t.datetime "expires_at"
    t.uuid "family_id", null: false
    t.uuid "inviter_id", null: false
    t.string "role"
    t.string "token"
    t.datetime "updated_at", null: false
    t.index ["email", "family_id"], name: "index_invitations_on_email_and_family_id", unique: true
    t.index ["email"], name: "index_invitations_on_email"
    t.index ["family_id"], name: "index_invitations_on_family_id"
    t.index ["inviter_id"], name: "index_invitations_on_inviter_id"
    t.index ["token"], name: "index_invitations_on_token", unique: true
  end

  create_table "invite_codes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.index ["token"], name: "index_invite_codes_on_token", unique: true
  end

  create_table "loans", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.decimal "initial_balance", precision: 19, scale: 4
    t.decimal "interest_rate", precision: 10, scale: 3
    t.jsonb "locked_attributes", default: {}
    t.string "rate_type"
    t.integer "term_months"
    t.datetime "updated_at", null: false
  end

  create_table "merchant_aliases", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "family_id", null: false
    t.bigint "merchant_id", null: false
    t.string "normalized_name", null: false
    t.string "raw_name", null: false
    t.string "source", default: "user_manual", null: false
    t.datetime "updated_at", null: false
    t.index ["family_id", "normalized_name"], name: "index_merchant_aliases_on_family_and_normalized_name", unique: true
    t.index ["family_id"], name: "index_merchant_aliases_on_family_id"
    t.index ["merchant_id"], name: "index_merchant_aliases_on_merchant_id"
    t.index ["source"], name: "index_merchant_aliases_on_source"
  end

  create_table "merchants", force: :cascade do |t|
    t.string "color"
    t.datetime "created_at", null: false
    t.uuid "family_id"
    t.string "logo_url"
    t.string "name", null: false
    t.string "provider_merchant_id"
    t.string "source"
    t.string "type", null: false
    t.datetime "updated_at", null: false
    t.string "website_url"
    t.index ["family_id", "name"], name: "index_merchants_on_family_id_and_name", unique: true, where: "((type)::text = 'FamilyMerchant'::text)"
    t.index ["family_id"], name: "index_merchants_on_family_id"
    t.index ["source", "name"], name: "index_merchants_on_source_and_name", unique: true, where: "((type)::text = 'ProviderMerchant'::text)"
    t.index ["type"], name: "index_merchants_on_type"
  end

  create_table "messages", force: :cascade do |t|
    t.string "ai_model"
    t.bigint "chat_id", null: false
    t.text "content"
    t.datetime "created_at", null: false
    t.boolean "debug", default: false
    t.string "provider_id"
    t.boolean "reasoning", default: false
    t.string "status", default: "complete", null: false
    t.string "type", null: false
    t.datetime "updated_at", null: false
    t.index ["chat_id"], name: "index_messages_on_chat_id"
  end

  create_table "mobile_devices", force: :cascade do |t|
    t.string "app_version"
    t.datetime "created_at", null: false
    t.string "device_id"
    t.string "device_name"
    t.string "device_type"
    t.datetime "last_seen_at"
    t.bigint "oauth_application_id"
    t.string "os_version"
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["oauth_application_id"], name: "index_mobile_devices_on_oauth_application_id"
    t.index ["user_id", "device_id"], name: "index_mobile_devices_on_user_id_and_device_id", unique: true
    t.index ["user_id"], name: "index_mobile_devices_on_user_id"
  end

  create_table "oauth_access_grants", force: :cascade do |t|
    t.bigint "application_id", null: false
    t.datetime "created_at", null: false
    t.integer "expires_in", null: false
    t.text "redirect_uri", null: false
    t.string "resource_owner_id", null: false
    t.datetime "revoked_at"
    t.string "scopes", default: "", null: false
    t.string "token", null: false
    t.index ["application_id"], name: "index_oauth_access_grants_on_application_id"
    t.index ["resource_owner_id"], name: "index_oauth_access_grants_on_resource_owner_id"
    t.index ["token"], name: "index_oauth_access_grants_on_token", unique: true
  end

  create_table "oauth_access_tokens", force: :cascade do |t|
    t.bigint "application_id", null: false
    t.datetime "created_at", null: false
    t.integer "expires_in"
    t.string "previous_refresh_token", default: "", null: false
    t.string "refresh_token"
    t.string "resource_owner_id"
    t.datetime "revoked_at"
    t.string "scopes"
    t.string "token", null: false
    t.index ["application_id"], name: "index_oauth_access_tokens_on_application_id"
    t.index ["refresh_token"], name: "index_oauth_access_tokens_on_refresh_token", unique: true
    t.index ["resource_owner_id"], name: "index_oauth_access_tokens_on_resource_owner_id"
    t.index ["token"], name: "index_oauth_access_tokens_on_token", unique: true
  end

  create_table "oauth_applications", force: :cascade do |t|
    t.boolean "confidential", default: true, null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.string "owner_id"
    t.string "owner_type"
    t.text "redirect_uri", null: false
    t.string "scopes", default: "", null: false
    t.string "secret", null: false
    t.string "uid", null: false
    t.datetime "updated_at", null: false
    t.index ["owner_id", "owner_type"], name: "index_oauth_applications_on_owner_id_and_owner_type"
    t.index ["uid"], name: "index_oauth_applications_on_uid", unique: true
  end

  create_table "other_assets", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "locked_attributes", default: {}
    t.datetime "updated_at", null: false
  end

  create_table "other_liabilities", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "locked_attributes", default: {}
    t.datetime "updated_at", null: false
  end

  create_table "pending_actions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "action_type", null: false
    t.jsonb "audit_result"
    t.datetime "confirmed_at"
    t.string "confirmed_by"
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.uuid "family_id", null: false
    t.jsonb "params", default: {}, null: false
    t.jsonb "preview", default: {}, null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id"
    t.index ["expires_at"], name: "index_pending_actions_on_expires_at"
    t.index ["family_id", "action_type"], name: "index_pending_actions_on_family_id_and_action_type"
  end

  create_table "plaid_accounts", force: :cascade do |t|
    t.decimal "available_balance", precision: 19, scale: 4
    t.datetime "created_at", null: false
    t.string "currency", null: false
    t.decimal "current_balance", precision: 19, scale: 4
    t.string "mask"
    t.string "name", null: false
    t.string "plaid_id", null: false
    t.uuid "plaid_item_id", null: false
    t.string "plaid_subtype"
    t.string "plaid_type", null: false
    t.json "raw_investments_payload", default: {}
    t.json "raw_liabilities_payload", default: {}
    t.json "raw_payload", default: {}
    t.json "raw_transactions_payload", default: {}
    t.datetime "updated_at", null: false
    t.index ["plaid_id"], name: "index_plaid_accounts_on_plaid_id", unique: true
    t.index ["plaid_item_id"], name: "index_plaid_accounts_on_plaid_item_id"
  end

  create_table "plaid_items", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "access_token"
    t.string "available_products", default: "[]"
    t.string "billed_products", default: "[]"
    t.datetime "created_at", null: false
    t.uuid "family_id", null: false
    t.string "institution_color"
    t.string "institution_id"
    t.string "institution_url"
    t.string "name"
    t.string "next_cursor"
    t.string "plaid_id", null: false
    t.string "plaid_region", default: "us", null: false
    t.json "raw_institution_payload", default: {}
    t.json "raw_payload", default: {}
    t.boolean "scheduled_for_deletion", default: false
    t.string "status", default: "good", null: false
    t.datetime "updated_at", null: false
    t.index ["family_id"], name: "index_plaid_items_on_family_id"
    t.index ["plaid_id"], name: "index_plaid_items_on_plaid_id", unique: true
  end

  create_table "properties", force: :cascade do |t|
    t.string "area_unit"
    t.integer "area_value"
    t.datetime "created_at", null: false
    t.jsonb "locked_attributes", default: {}
    t.datetime "updated_at", null: false
    t.integer "year_built"
  end

  create_table "rejected_transfers", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "inflow_transaction_id", null: false
    t.bigint "outflow_transaction_id", null: false
    t.datetime "updated_at", null: false
    t.index ["inflow_transaction_id", "outflow_transaction_id"], name: "idx_on_inflow_transaction_id_outflow_transaction_id_412f8e7e26", unique: true
    t.index ["inflow_transaction_id"], name: "index_rejected_transfers_on_inflow_transaction_id"
    t.index ["outflow_transaction_id"], name: "index_rejected_transfers_on_outflow_transaction_id"
  end

  create_table "rule_actions", force: :cascade do |t|
    t.string "action_type", null: false
    t.datetime "created_at", null: false
    t.bigint "rule_id", null: false
    t.datetime "updated_at", null: false
    t.string "value"
    t.index ["rule_id"], name: "index_rule_actions_on_rule_id"
  end

  create_table "rule_conditions", force: :cascade do |t|
    t.string "condition_type", null: false
    t.datetime "created_at", null: false
    t.string "operator", null: false
    t.bigint "parent_id"
    t.bigint "rule_id"
    t.datetime "updated_at", null: false
    t.string "value"
    t.index ["parent_id"], name: "index_rule_conditions_on_parent_id"
    t.index ["rule_id"], name: "index_rule_conditions_on_rule_id"
  end

  create_table "rules", force: :cascade do |t|
    t.boolean "active", default: false, null: false
    t.datetime "created_at", null: false
    t.date "effective_date"
    t.uuid "family_id", null: false
    t.string "name"
    t.string "resource_type", null: false
    t.datetime "updated_at", null: false
    t.index ["family_id"], name: "index_rules_on_family_id"
  end

  create_table "securities", force: :cascade do |t|
    t.string "country_code"
    t.datetime "created_at", null: false
    t.string "exchange_acronym"
    t.string "exchange_mic"
    t.string "exchange_operating_mic"
    t.datetime "failed_fetch_at"
    t.integer "failed_fetch_count", default: 0, null: false
    t.datetime "last_health_check_at"
    t.string "logo_url"
    t.string "name"
    t.boolean "offline", default: false, null: false
    t.string "ticker", null: false
    t.datetime "updated_at", null: false
    t.index "upper((ticker)::text), COALESCE(upper((exchange_operating_mic)::text), ''::text)", name: "index_securities_on_ticker_and_exchange_operating_mic_unique", unique: true
    t.index ["country_code"], name: "index_securities_on_country_code"
    t.index ["exchange_operating_mic"], name: "index_securities_on_exchange_operating_mic"
  end

  create_table "security_prices", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "currency", default: "USD", null: false
    t.date "date", null: false
    t.decimal "price", precision: 19, scale: 4, null: false
    t.bigint "security_id"
    t.datetime "updated_at", null: false
    t.index ["security_id", "date", "currency"], name: "index_security_prices_on_security_id_and_date_and_currency", unique: true
    t.index ["security_id"], name: "index_security_prices_on_security_id"
  end

  create_table "sessions", force: :cascade do |t|
    t.bigint "active_impersonator_session_id"
    t.datetime "created_at", null: false
    t.json "data", default: {}
    t.string "ip_address"
    t.json "prev_transaction_page_params", default: {}
    t.datetime "subscribed_at"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.uuid "user_id", null: false
    t.index ["active_impersonator_session_id"], name: "index_sessions_on_active_impersonator_session_id"
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "settings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "value"
    t.string "var", null: false
    t.index ["var"], name: "index_settings_on_var", unique: true
  end

  create_table "subscriptions", force: :cascade do |t|
    t.decimal "amount", precision: 19, scale: 4
    t.datetime "created_at", null: false
    t.string "currency"
    t.datetime "current_period_ends_at"
    t.uuid "family_id", null: false
    t.string "interval"
    t.string "status", null: false
    t.string "stripe_id"
    t.datetime "trial_ends_at"
    t.datetime "updated_at", null: false
    t.index ["family_id"], name: "index_subscriptions_on_family_id", unique: true
  end

  create_table "syncs", force: :cascade do |t|
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.json "data"
    t.string "error"
    t.datetime "failed_at"
    t.bigint "parent_id"
    t.datetime "pending_at"
    t.string "status", default: "pending"
    t.uuid "syncable_id", null: false
    t.string "syncable_type", null: false
    t.datetime "syncing_at"
    t.datetime "updated_at", null: false
    t.date "window_end_date"
    t.date "window_start_date"
    t.index ["parent_id"], name: "index_syncs_on_parent_id"
    t.index ["status"], name: "index_syncs_on_status"
    t.index ["syncable_type", "syncable_id"], name: "index_syncs_on_syncable"
  end

  create_table "taggings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "tag_id", null: false
    t.bigint "taggable_id"
    t.string "taggable_type"
    t.datetime "updated_at", null: false
    t.index ["tag_id"], name: "index_taggings_on_tag_id"
    t.index ["taggable_type", "taggable_id"], name: "index_taggings_on_taggable"
  end

  create_table "tags", force: :cascade do |t|
    t.string "color", default: "#e99537", null: false
    t.datetime "created_at", null: false
    t.uuid "family_id", null: false
    t.string "name"
    t.datetime "updated_at", null: false
    t.index ["family_id"], name: "index_tags_on_family_id"
  end

  create_table "tool_calls", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.json "function_arguments"
    t.string "function_name"
    t.json "function_result"
    t.bigint "message_id", null: false
    t.string "provider_call_id"
    t.string "provider_id", null: false
    t.string "type", null: false
    t.datetime "updated_at", null: false
    t.index ["message_id"], name: "index_tool_calls_on_message_id"
  end

  create_table "trades", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "currency"
    t.jsonb "locked_attributes", default: {}
    t.decimal "price", precision: 19, scale: 4
    t.decimal "qty", precision: 19, scale: 4
    t.bigint "security_id", null: false
    t.datetime "updated_at", null: false
    t.index ["security_id"], name: "index_trades_on_security_id"
  end

  create_table "transactions", force: :cascade do |t|
    t.bigint "category_id"
    t.datetime "created_at", null: false
    t.string "kind", default: "standard", null: false
    t.jsonb "locked_attributes", default: {}
    t.bigint "merchant_id"
    t.datetime "updated_at", null: false
    t.index ["category_id"], name: "index_transactions_on_category_id"
    t.index ["kind"], name: "index_transactions_on_kind"
    t.index ["merchant_id"], name: "index_transactions_on_merchant_id"
  end

  create_table "transfers", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "inflow_transaction_id", null: false
    t.text "notes"
    t.bigint "outflow_transaction_id", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["inflow_transaction_id", "outflow_transaction_id"], name: "idx_on_inflow_transaction_id_outflow_transaction_id_8cd07a28bd", unique: true
    t.index ["inflow_transaction_id"], name: "index_transfers_on_inflow_transaction_id"
    t.index ["outflow_transaction_id"], name: "index_transfers_on_outflow_transaction_id"
    t.index ["status"], name: "index_transfers_on_status"
  end

  create_table "users", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.boolean "ai_enabled", default: false, null: false
    t.datetime "created_at", null: false
    t.string "default_period", default: "last_30_days", null: false
    t.string "email"
    t.uuid "family_id", null: false
    t.string "first_name"
    t.text "goals", default: "[]"
    t.string "last_name"
    t.bigint "last_viewed_chat_id"
    t.datetime "onboarded_at"
    t.string "otp_backup_codes", default: "[]"
    t.boolean "otp_required", default: false, null: false
    t.string "otp_secret"
    t.string "password_digest"
    t.string "role", default: "member", null: false
    t.datetime "rule_prompt_dismissed_at"
    t.boolean "rule_prompts_disabled", default: false
    t.datetime "set_onboarding_goals_at"
    t.datetime "set_onboarding_preferences_at"
    t.boolean "show_ai_sidebar", default: true
    t.boolean "show_sidebar", default: true
    t.string "theme", default: "system"
    t.string "unconfirmed_email"
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["family_id"], name: "index_users_on_family_id"
    t.index ["last_viewed_chat_id"], name: "index_users_on_last_viewed_chat_id"
    t.index ["otp_secret"], name: "index_users_on_otp_secret", unique: true, where: "(otp_secret IS NOT NULL)"
    t.check_constraint "role::text = ANY (ARRAY['admin'::character varying, 'member'::character varying, 'super_admin'::character varying]::text[])", name: "check_user_role"
  end

  create_table "valuations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "kind", default: "reconciliation", null: false
    t.jsonb "locked_attributes", default: {}
    t.datetime "updated_at", null: false
  end

  create_table "vehicles", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "locked_attributes", default: {}
    t.string "make"
    t.string "mileage_unit"
    t.integer "mileage_value"
    t.string "model"
    t.datetime "updated_at", null: false
    t.integer "year"
  end

  add_foreign_key "accounts", "families"
  add_foreign_key "accounts", "imports"
  add_foreign_key "accounts", "plaid_accounts"
  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "api_keys", "users"
  add_foreign_key "balances", "accounts", on_delete: :cascade
  add_foreign_key "budget_categories", "budgets"
  add_foreign_key "budget_categories", "categories"
  add_foreign_key "budgets", "families"
  add_foreign_key "categories", "families"
  add_foreign_key "chats", "users"
  add_foreign_key "entries", "accounts"
  add_foreign_key "entries", "imports"
  add_foreign_key "family_exports", "families"
  add_foreign_key "holdings", "accounts"
  add_foreign_key "holdings", "securities"
  add_foreign_key "impersonation_session_logs", "impersonation_sessions"
  add_foreign_key "impersonation_sessions", "users", column: "impersonated_id"
  add_foreign_key "impersonation_sessions", "users", column: "impersonator_id"
  add_foreign_key "import_rows", "imports"
  add_foreign_key "imports", "families"
  add_foreign_key "invitations", "families"
  add_foreign_key "invitations", "users", column: "inviter_id"
  add_foreign_key "merchant_aliases", "families"
  add_foreign_key "merchant_aliases", "merchants"
  add_foreign_key "merchants", "families"
  add_foreign_key "messages", "chats"
  add_foreign_key "mobile_devices", "users"
  add_foreign_key "oauth_access_grants", "oauth_applications", column: "application_id"
  add_foreign_key "oauth_access_tokens", "oauth_applications", column: "application_id"
  add_foreign_key "plaid_accounts", "plaid_items"
  add_foreign_key "plaid_items", "families"
  add_foreign_key "rejected_transfers", "transactions", column: "inflow_transaction_id"
  add_foreign_key "rejected_transfers", "transactions", column: "outflow_transaction_id"
  add_foreign_key "rule_actions", "rules"
  add_foreign_key "rule_conditions", "rule_conditions", column: "parent_id"
  add_foreign_key "rule_conditions", "rules"
  add_foreign_key "rules", "families"
  add_foreign_key "security_prices", "securities"
  add_foreign_key "sessions", "impersonation_sessions", column: "active_impersonator_session_id"
  add_foreign_key "sessions", "users"
  add_foreign_key "subscriptions", "families"
  add_foreign_key "syncs", "syncs", column: "parent_id"
  add_foreign_key "taggings", "tags"
  add_foreign_key "tags", "families"
  add_foreign_key "tool_calls", "messages"
  add_foreign_key "trades", "securities"
  add_foreign_key "transactions", "categories", on_delete: :nullify
  add_foreign_key "transactions", "merchants"
  add_foreign_key "transfers", "transactions", column: "inflow_transaction_id", on_delete: :cascade
  add_foreign_key "transfers", "transactions", column: "outflow_transaction_id", on_delete: :cascade
  add_foreign_key "users", "chats", column: "last_viewed_chat_id"
  add_foreign_key "users", "families"
end
