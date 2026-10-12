class Rule::Registry::TransactionResource < Rule::Registry
  def resource_scope
    family.transactions.visible.with_entry.where(entry: { date: rule.effective_date.. })
  end

  def condition_filters
    [
      Rule::ConditionFilter::TransactionName.new(rule),
      Rule::ConditionFilter::TransactionAmount.new(rule),
      Rule::ConditionFilter::TransactionMerchant.new(rule)
    ]
  end

  def action_executors
    enabled_executors = [
      Rule::ActionExecutor::SetTransactionCategory.new(rule),
      Rule::ActionExecutor::SetTransactionTags.new(rule),
      Rule::ActionExecutor::SetTransactionMerchant.new(rule),
      Rule::ActionExecutor::SetTransactionName.new(rule)
    ]

    if ai_enabled?
      enabled_executors << Rule::ActionExecutor::AutoCategorize.new(rule)
      enabled_executors << Rule::ActionExecutor::AutoDetectMerchants.new(rule)
    end

    enabled_executors
  end

  private
    # The AI actions above (auto-categorize, auto-detect merchants) are powered
    # by LLM enrichment capabilities the RubyLLM provider contract does not
    # implement yet — they are deferred to #15 and #30. RubyLLM is the only LLM
    # provider and always returns an instance, so a bare provider-presence check
    # would advertise actions the provider cannot perform, promising an
    # unsupported operation. Keep the affordance disabled until those
    # capabilities land rather than routing to any provider.
    def ai_enabled?
      false
    end
end
