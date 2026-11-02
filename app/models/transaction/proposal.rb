module Transaction::Proposal
  # Prepares an inspectable create_transaction proposal for a trusted family.
  # The family is always a server-bound object; it is never resolved from
  # caller params. Defaults apply to the preview only, so the stored params stay
  # exactly as the caller supplied them (minus server attribution keys).
  def self.prepare!(family:, params:, user: nil, idempotency_key: nil)
    normalized = params.to_h.transform_keys(&:to_s)
    account = family.accounts.find(normalized["account_id"])
    currency = normalized["currency"] || family.currency
    amount = BigDecimal(normalized["amount"])
    kind = normalized["kind"] || "standard"

    preview = {
      action: "create_transaction",
      account_name: account.name,
      date: normalized["date"],
      name: normalized["name"],
      amount: amount.to_s,
      currency: currency,
      kind: kind,
      category_id: normalized["category_id"],
      merchant_id: normalized["merchant_id"]
    }

    PendingAction.create_pending!(
      action_type: "create_transaction",
      params: normalized.except("user_id", "idempotency_key"),
      preview: preview,
      family: family,
      user: user,
      idempotency_key: idempotency_key
    )
  end
end
