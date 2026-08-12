module Assistant::Provided
  extend ActiveSupport::Concern

  def get_model_provider(ai_model)
    provider = registry.providers.find { |p| p&.supports_model?(ai_model) }

    raise Provider::Registry::Error, "No enabled LLM provider supports model reference '#{ai_model}'" unless provider.present?

    provider
  end

  private
    def registry
      @registry ||= Provider::Registry.for_concept(:llm)
    end
end
