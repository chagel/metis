module Agent
  # Resolves an explicit model/provider choice against the deployment LLM
  # catalog, layered over base settings. Shared by chat-started workflows
  # (Agent::WorkflowHandoff) and routines (Agent::RoutineManager). Returns
  # [settings, error]: on error `settings` is nil and `error` is a human string
  # the agent relays; otherwise `error` is nil.
  #
  # No catalog synced at all → the values pass through (pi validates them
  # itself). A synced catalog with everything disabled still rejects, so chat
  # can't bypass operator curation. Both --provider and --model are always set
  # together so a provider switch never keeps a model from the old provider.
  class ModelSelection
    def self.resolve(base_settings, model:, provider:)
      new(base_settings, model, provider).resolve
    end

    def initialize(base_settings, model, provider)
      @settings = (base_settings || {}).dup
      @model = model.to_s.strip
      @provider = provider.to_s.strip
    end

    def resolve
      return [ @settings, nil ] if @model.blank? && @provider.blank?

      unless LlmModel.exists?
        @settings["model"] = @model if @model.present?
        @settings["provider"] = @provider if @provider.present?
        return [ @settings, nil ]
      end

      found, error = @model.present? ? find_model(@model, @provider) : find_provider_default(@provider)
      return [ nil, error ] if error

      @settings["model"] = found.key
      @settings["provider"] = found.llm_provider.key
      [ @settings, nil ]
    end

    private

    # Match by pi model key first, then the operator-facing label, optionally
    # scoped to a named provider. Keys aren't unique across providers, so an
    # unscoped match spanning providers is ambiguous — fail and ask.
    def find_model(value, provider_value)
      scope = LlmModel.enabled
      if provider_value.present?
        provider = find_provider(provider_value)
        return [ nil, "No enabled provider #{quoted(provider_value)} in the catalog." ] unless provider

        scope = scope.where(llm_provider: provider)
      end

      matches = scope.where(key: value).to_a
      matches = scope.where("LOWER(label) = LOWER(?)", value).to_a if matches.empty?
      return [ nil, "No enabled model #{quoted(value)} in the catalog. Available: #{available_models}." ] if matches.empty?

      providers = matches.map(&:llm_provider).uniq
      if providers.size > 1
        return [ nil, "Model #{quoted(value)} exists under multiple providers (#{providers.map(&:key).sort.join(", ")}) — name a provider." ]
      end

      [ matches.first, nil ]
    end

    # Provider without a model — run its default (first enabled) model so the
    # pair is always valid.
    def find_provider_default(value)
      provider = find_provider(value)
      return [ nil, "No enabled provider #{quoted(value)} in the catalog." ] unless provider

      model = provider.llm_models.enabled.ordered.first
      return [ nil, "Provider #{quoted(value)} has no enabled models in the catalog." ] unless model

      [ model, nil ]
    end

    def find_provider(value)
      provider = LlmProvider.find_by(key: value) || LlmProvider.where("LOWER(label) = LOWER(?)", value).first
      provider if provider&.enabled?
    end

    def available_models
      LlmModel.enabled.ordered.limit(20).pluck(:key).join(", ")
    end

    def quoted(value) = "\"#{value.presence || "?"}\""
  end
end
