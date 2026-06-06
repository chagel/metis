require "shellwords"

module Agent
  # Mirrors pi's available-models catalog into LlmProvider / LlmModel rows.
  #
  # pi (get_available_models) is the source of truth for *what exists*; the
  # rows add what pi has no concept of — operator curation (enabled, label,
  # ordering). Curation is sticky: a refresh updates pi-derived metadata but
  # never clobbers enabled / label / position on rows that already exist.
  # Models pi no longer reports are
  # kept (and shown stale by last_seen_at), never deleted — a key may just
  # be temporarily unset.
  #
  # Deployment-level, like provider API keys (VISION rule 4).
  module ModelCatalogSync
    module_function

    # Returns { providers:, models:, ok: } — ok false when pi was
    # unreachable (callers surface this; nothing is mutated in that case).
    def call
      payload = fetch_models
      return { providers: 0, models: 0, ok: false } if payload.blank?

      seen = 0
      payload.group_by { |model| model["provider"] }.each do |provider_key, group|
        provider = upsert_provider(provider_key)
        group.each do |model|
          upsert_model(provider, model)
          seen += 1
        end
      end
      { providers: LlmProvider.count, models: seen, ok: true }
    end

    # Ask the configured runtime's pi what models it offers. The runtime
    # owns *how* pi is reached (local subprocess, docker run, E2b microVM);
    # the catalog is a property of that runtime's pi build. The provider
    # keys go along so pi advertises the providers this deployment can use.
    def fetch_models
      Agent::Runtime.control_session(env: api_key_env) { |session| session.available_models }
    rescue StandardError => e
      Rails.logger.warn("Agent::ModelCatalogSync fetch failed: #{e.message}")
      nil
    end

    def api_key_env
      metadata = Rails.application.config.x.agent.provider_metadata
      Rails.application.config.x.agent.api_keys.to_h.filter_map do |provider, value|
        env_name = metadata.dig(provider, :env)
        [ env_name, value ] if env_name && value.present?
      end.to_h
    end

    def upsert_provider(key)
      provider = LlmProvider.find_or_initialize_by(key: key)
      if provider.new_record?
        provider.label = Rails.application.config.x.agent.provider_metadata.dig(key, :label) || key.to_s.titleize
        provider.position = LlmProvider.maximum(:position).to_i + 1
      end
      provider.save!
      provider
    end

    def upsert_model(provider, data)
      model = provider.llm_models.find_or_initialize_by(key: data["id"])
      if model.new_record?
        model.label = data["name"].presence || data["id"]
        model.position = provider.llm_models.maximum(:position).to_i + 1
      end
      model.context_window  = data["contextWindow"]
      model.max_tokens      = data["maxTokens"]
      model.reasoning       = data["reasoning"] ? true : false
      model.input_modalities = data["input"] || []
      model.cost            = data["cost"] || {}
      model.last_seen_at    = Time.current
      model.save!
      model
    end
  end
end
