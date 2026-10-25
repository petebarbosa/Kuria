require "digest"

class PendingAction < ApplicationRecord
  belongs_to :family
  belongs_to :user, optional: true

  validates :action_type, presence: true
  validates :params, :preview, :expires_at, presence: true
  validate :preview_not_empty

  scope :not_expired, -> { where("expires_at > ?", Time.current) }
  scope :pending, -> { not_expired.where(confirmed_at: nil) }

  TTL = 10.minutes

  class << self
    def create_pending!(action_type:, params:, preview:, family:, user: nil, idempotency_key: nil)
      validate_user!(user, family)
      validate_references!(action_type, params, family)

      attributes = {
        action_type: action_type,
        params: params,
        preview: preview,
        family: family,
        user: user,
        expires_at: TTL.from_now
      }

      key = idempotency_key.presence
      return create!(attributes) unless key

      attributes[:id] = deterministic_id(
        family: family,
        user: user,
        action_type: action_type,
        idempotency_key: key
      )
      create_idempotent!(attributes)
    end

    def confirm_and_execute!(id:, confirmed_by: nil, family: nil)
      action = confirmation_scope(family).find_by(id: id)
      return nil unless action
      return nil if confirmed_by.is_a?(User) && confirmed_by.family_id != action.family_id

      action.with_lock do
        if action.confirmed?
          record_rejected_attempt!(action, "already_confirmed", confirmed_by)
          nil
        elsif action.expired?
          record_rejected_attempt!(action, "expired", confirmed_by)
          nil
        else
          result = execute_in_savepoint!(action)
          attempt = confirmation_attempt(
            "confirmed",
            confirmed_by,
            execution_status: result.is_a?(Hash) && result["success"] == true ? "succeeded" : "failed"
          )
          action.update!(
            confirmed_at: Time.current,
            confirmed_by: confirmer_identifier(confirmed_by),
            audit_result: append_confirmation_attempt(action, attempt, execution_result: result)
          )
          update_tool_call_audits!(action, attempt)
          action
        end
      end
    end

    private

      def confirmation_scope(family)
        family ? where(family: family) : all
      end

      # Executors rescue their own failures and return a result hash, so a
      # failed execution must be signalled as a savepoint rollback. Financial
      # writes then disappear while the outer row lock and the consumed-action
      # marker/audit remain committed.
      def execute_in_savepoint!(action)
        result = nil

        transaction(requires_new: true) do
          result = action.execute!
          result = result.is_a?(Hash) ? result.deep_stringify_keys : {}
          raise ActiveRecord::Rollback unless result["success"] == true
        end

        result
      end

      def record_rejected_attempt!(action, reason, confirmed_by)
        attempt = confirmation_attempt("rejected", confirmed_by, reason: reason)
        audit = append_confirmation_attempt(action, attempt)
        action.update!(audit_result: audit)
        update_tool_call_audits!(action, attempt, execution_status: audit["execution_status"])
        attempt
      end

      def confirmation_attempt(status, confirmed_by, reason: nil, execution_status: nil)
        {
          "status" => status,
          "reason" => reason,
          "confirmed_by" => confirmer_identifier(confirmed_by),
          "execution_status" => execution_status,
          "at" => Time.current.iso8601
        }.compact
      end

      # Keeps the outcome that changed the action under "confirmation" and the
      # latest attempt (including replays) under "last_confirmation_attempt".
      # The full attempt history survives in "confirmation_attempts".
      def append_confirmation_attempt(action, attempt, execution_result: nil)
        audit = if execution_result
          execution_result.deep_dup
        elsif action.audit_result.is_a?(Hash)
          action.audit_result.deep_dup
        else
          {}
        end

        audit["success"] = false if attempt["reason"] == "expired" && !audit.key?("success")
        record_execution_status!(audit, attempt, derive_from_success: attempt["reason"] == "already_confirmed")

        if attempt["status"] == "confirmed"
          audit["confirmation"] = attempt
        else
          audit["confirmation"] ||= attempt
        end

        audit["last_confirmation_attempt"] = attempt
        audit["confirmation_attempts"] = Array(audit["confirmation_attempts"]) + [ attempt ]
        audit
      end

      # Legacy confirmed actions may only carry "success". Derive the enum from
      # it on replay; when neither field exists, leave the outcome unknown.
      def record_execution_status!(audit, attempt, derive_from_success: false)
        if attempt["execution_status"].present?
          audit["execution_status"] = attempt["execution_status"]
          return
        end

        return if audit["execution_status"].present?

        status = derived_execution_status(audit) if derive_from_success
        audit["execution_status"] = status if status
      end

      def derived_execution_status(audit)
        return "succeeded" if audit["success"] == true
        return "failed" if audit["success"] == false

        nil
      end

      def update_tool_call_audits!(action, attempt, execution_status: nil)
        ToolCall::Function
          .where("function_result ->> 'pending_action_id' = ?", action.id)
          .find_each do |call|
            call.update!(
              function_result: append_tool_confirmation_attempt(
                call.function_result,
                attempt,
                execution_status: execution_status
              )
            )
          end
      end

      def append_tool_confirmation_attempt(result, attempt, execution_status: nil)
        audit = result.is_a?(Hash) ? result.deep_dup : {}
        if execution_status.present?
          audit["execution_status"] = execution_status
        else
          record_execution_status!(audit, attempt)
        end

        if attempt["status"] == "confirmed"
          audit["confirmation"] = attempt
        else
          audit["confirmation"] ||= attempt
        end

        audit["last_confirmation_attempt"] = attempt
        audit["confirmation_attempts"] = Array(audit["confirmation_attempts"]) + [ attempt ]
        audit
      end

      def confirmer_identifier(confirmed_by)
        confirmed_by.is_a?(User) ? confirmed_by.id : confirmed_by
      end

      # A retry of the same provider tool call must return the original
      # proposal instead of creating another actionable action. The primary key
      # is derived from the family, user, action, and provider idempotency key,
      # so the database's unique constraint resolves concurrent duplicates.
      def create_idempotent!(attributes)
        existing = find_by(id: attributes[:id])
        return existing if existing

        transaction(requires_new: true) { create!(attributes) }
      rescue ActiveRecord::RecordNotUnique
        find_by!(id: attributes[:id])
      end

      def deterministic_id(family:, user:, action_type:, idempotency_key:)
        digest = Digest::SHA256.hexdigest(
          [ family.id, user&.id, action_type, idempotency_key ].map(&:to_s).join("\0")
        )
        hex = digest[0, 32]
        hex[12] = "5"
        hex[16] = ((hex[16].to_i(16) & 0x3) | 0x8).to_s(16)

        [ hex[0, 8], hex[8, 4], hex[12, 4], hex[16, 4], hex[20, 12] ].join("-")
      end

      def validate_user!(user, family)
        return if user.nil?

        family.users.find(user.id)
      end

      def validate_references!(action_type, params, family)
        return unless action_type == "create_transaction"

        validate_account_reference!(params, family)
        validate_category_reference!(params, family)
        validate_merchant_reference!(params, family)
      end

      def validate_account_reference!(params, family)
        return if family.accounts.exists?(id: param_value(params, "account_id"))

        raise ActiveRecord::RecordNotFound, "Account not found for family"
      end

      def validate_category_reference!(params, family)
        id = param_value(params, "category_id")
        return if id.blank? || family.categories.exists?(id: id)

        raise ActiveRecord::RecordNotFound, "Category not found for family"
      end

      def validate_merchant_reference!(params, family)
        id = param_value(params, "merchant_id")
        return if id.blank? || family.merchants.exists?(id: id)

        raise ActiveRecord::RecordNotFound, "Merchant not found for family"
      end

      def param_value(params, key)
        params[key] || params[key.to_sym]
      end
  end

  def expired?
    expires_at <= Time.current
  end

  def confirmed?
    confirmed_at.present?
  end

  def execute!
    raise "Already confirmed" if confirmed?
    raise "Expired" if expired?

    case action_type
    when "create_transaction"
      execute_create_transaction
    when "update_transaction"
      execute_update_transaction
    when "create_or_update_budget"
      execute_create_or_update_budget
    when "create_or_update_budget_category"
      execute_create_or_update_budget_category
    when "upsert_exchange_rates"
      execute_upsert_exchange_rates
    else
      raise "Unknown action type: #{action_type}"
    end
  end

  private

    def preview_not_empty
      errors.add(:preview, "must not be empty") if preview.is_a?(Hash) && preview.empty?
    end

    def execute_create_transaction
      account = family.accounts.find(params["account_id"])
      entry = Entry.create!(
        account: account,
        date: Date.parse(params["date"]),
        name: params["name"],
        amount: BigDecimal(params["amount"]),
        currency: params["currency"] || family.currency,
        entryable: Transaction.new(
          category_id: params["category_id"],
          merchant_id: params["merchant_id"],
          kind: params["kind"] || "standard"
        )
      )
      { success: true, entry_id: entry.id, transaction_id: entry.entryable_id }
    rescue => e
      { success: false, error: e.message }
    end

    def execute_update_transaction
      entry = Entry.find(params["entry_id"])
      raise "Entry does not belong to family" unless entry.account.family_id == family.id

      update_attrs = {
        date: params["date"] ? Date.parse(params["date"]) : nil,
        name: params["name"],
        amount: params["amount"] ? BigDecimal(params["amount"]) : nil,
        currency: params["currency"]
      }.compact_blank

      transaction_attrs = {
        category_id: params["category_id"],
        merchant_id: params["merchant_id"],
        kind: params["kind"]
      }.compact_blank

      entry.update!(update_attrs) if update_attrs.any?
      entry.entryable.update!(transaction_attrs) if transaction_attrs.any?

      { success: true, entry_id: entry.id }
    rescue => e
      { success: false, error: e.message }
    end

    def execute_create_or_update_budget
      month_date = Budget.param_to_date(params["month_year"])
      budget = Budget.find_or_bootstrap(family, start_date: month_date)
      return { success: false, error: "Invalid budget date" } unless budget

      if params.key?("budgeted_spending")
        budget.update!(budgeted_spending: BigDecimal(params["budgeted_spending"]))
      end

      { success: true, budget_id: budget.id, month: budget.name }
    rescue => e
      { success: false, error: e.message }
    end

    def execute_create_or_update_budget_category
      month_date = Budget.param_to_date(params["month_year"])
      budget = Budget.find_or_bootstrap(family, start_date: month_date)
      return { success: false, error: "Invalid budget date" } unless budget

      budget_category = budget.budget_categories.find_or_initialize_by(
        category_id: params["category_id"]
      )
      budget_category.update!(
        budgeted_spending: BigDecimal(params["budgeted_spending"])
      )

      { success: true, budget_category_id: budget_category.id, category_name: budget_category.category.name }
    rescue => e
      { success: false, error: e.message }
    end

    def execute_upsert_exchange_rates
      rates = params["rates"]
      return { success: false, error: "No rates provided" } unless rates.is_a?(Array) && rates.any?

      upserted = 0
      errors = []

      rates.each do |rate_params|
        rate = ExchangeRate.find_or_initialize_by(
          from_currency: rate_params["from_currency"],
          to_currency: rate_params["to_currency"],
          date: Date.parse(rate_params["date"])
        )
        rate.rate = BigDecimal(rate_params["rate"])
        if rate.save
          upserted += 1
        else
          errors << "#{rate_params["from_currency"]}/#{rate_params["to_currency"]} on #{rate_params["date"]}: #{rate.errors.full_messages.join(", ")}"
        end
      end

      { success: true, upserted: upserted, errors: errors }
    rescue => e
      { success: false, error: e.message }
    end
end
