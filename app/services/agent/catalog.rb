module Agent
  # Provider/model options offered in the new-chat composer.
  #
  # Sourced from the deployment's LLM catalog — LlmProvider / LlmModel rows
  # that a superuser curates and Agent::ModelCatalogSync refreshes from pi.
  # Empty before the first sync: the composer renders no options and pi runs
  # on its own configured default.
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
      provider_for(model_id, provider_options).present?
    end

    # The deployment default: the model a superuser marked on the Models
    # page, else the first listed provider's first model.
    def self.default_model(provider_options = providers)
      marked = LlmModel.find_by(deployment_default: true)&.key
      return marked if marked && known_model?(marked, provider_options)

      provider_options.first&.dig(:models)&.first&.dig(:id)
    end

    def self.default_provider(provider_options = providers)
      provider_for(default_model(provider_options), provider_options) || provider_options.first&.dig(:id)
    end
  end
end
