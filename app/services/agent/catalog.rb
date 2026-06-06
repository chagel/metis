module Agent
  # Provider/model options offered in the new-chat composer.
  #
  # Sourced from the deployment's LLM catalog — LlmProvider / LlmModel rows
  # that a superuser curates and Agent::ModelCatalogSync refreshes from pi.
  # Empty before the first sync: the composer renders no options and a turn
  # falls back to the deployment default (config.x.agent / Conversation).
  # The chosen values land in Conversation#settings and are passed through
  # verbatim as pi's --provider/--model.
  module Catalog
    # Providers with at least one enabled model, grouped for the composer.
    def self.providers
      LlmProvider.ordered.includes(:llm_models).filter_map do |provider|
        models = provider.llm_models.select(&:enabled?).sort_by { |model| [ model.position, model.key ] }
        next if models.empty?

        { id: provider.key, label: provider.label,
          models: models.map { |model| { id: model.key, label: model.label } } }
      end
    end

    # Models grouped by provider for a single <select>, in the shape
    # grouped_options_for_select wants:
    #   [["Anthropic", [["Claude Opus 4.8", "claude-opus-4-8"], ...]], ...]
    def self.grouped_model_options(provider_options = providers)
      provider_options.map do |provider|
        models = provider[:models].map { |model| [ model[:label], model[:id] ] }
        [ provider[:label], models ]
      end
    end

    # The provider that offers a given model id, or nil if unknown.
    def self.provider_for(model_id, provider_options = providers)
      match = provider_options.find do |provider|
        provider[:models].any? { |model| model[:id] == model_id }
      end
      match&.fetch(:id)
    end

    def self.known_model?(model_id, provider_options = providers)
      return true if provider_for(model_id, provider_options)

      provider_options.empty? && !LlmModel.exists? &&
        model_id == Rails.application.config.x.agent.model.presence
    end

    # Model pre-selected in the composer: the configured env default when
    # it's in the catalog, else the default provider's first model.
    def self.default_model(provider_options = providers)
      configured = Rails.application.config.x.agent.model.presence
      return configured if configured && known_model?(configured, provider_options)

      provider = provider_options.find { |p| p[:id] == default_provider(provider_options) }
      provider&.dig(:models)&.first&.dig(:id)
    end

    # Provider pre-selected in the composer: the configured env default,
    # else the first listed.
    def self.default_provider(provider_options = providers)
      configured = Rails.application.config.x.agent.provider.presence
      ids = provider_options.map { |provider| provider[:id] }
      ids.include?(configured) ? configured : ids.first
    end
  end
end
