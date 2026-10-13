class MerchantResolver
  Result = Data.define(:merchant, :method, :confidence)

  def initialize(family)
    @family = family
  end

  def resolve(raw_name)
    normalized = MerchantNameNormalizer.normalize(raw_name)
    return Result.new(merchant: nil, method: :no_match, confidence: 0.0) if normalized.blank?

    alias_record = @family.merchant_aliases.find_by(normalized_name: normalized)
    if alias_record
      return Result.new(merchant: alias_record.merchant, method: :alias_exact, confidence: 1.0)
    end

    ai_result = try_ai_suggestion(raw_name, normalized)
    return ai_result if ai_result && ai_result.confidence >= 0.8

    Result.new(merchant: nil, method: :needs_user_resolution, confidence: 0.0)
  end

  def try_ai_suggestion(raw_name, normalized)
    llm_provider = Provider::Registry.get_provider(:ruby_llm)
    return nil unless llm_provider

    user_merchants = @family.merchants.map { |m| { id: m.id, name: m.name } }

    response = llm_provider.suggest_merchant(
      raw_name: raw_name,
      normalized_name: normalized,
      user_merchants: user_merchants,
      model: @family.enrichment_model
    )

    return nil unless response && response.success?

    suggestion = response.data
    return nil unless suggestion

    merchant = @family.merchants.find_by(id: suggestion.merchant_id)
    return nil unless merchant

    Result.new(
      merchant: merchant,
      method: :ai_suggested,
      confidence: suggestion.confidence || 0.0
    )
  rescue => e
    Rails.logger.error("AI merchant suggestion failed: #{e.message}")
    nil
  end
end
