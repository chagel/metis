# The deployment's LLM catalog under /settings — list providers/models,
# refresh from pi, and toggle availability. The page is readable by any
# member; mutations are superuser-only.
class ModelsController < ApplicationController
  layout "settings"

  before_action :require_superuser!, except: :index

  def index
    @providers = LlmProvider.ordered.includes(:llm_models)
    @default = LlmModel.enabled.find_by(deployment_default: true)
    @fallback_label = @providers.flat_map(&:llm_models).find { |m| m.key == Agent::Catalog.default_model }&.label
    @default_options = @providers.filter_map do |provider|
      models = provider.llm_models.select(&:enabled?).sort_by { |m| [ m.position, m.key ] }
      [ provider.label, models.map { |m| [ m.label, m.id ] } ] if models.any?
    end
  end

  def update_default
    LlmModel.enabled.find(params[:model_id]).make_deployment_default!
    redirect_to models_path
  end

  def refresh
    # Run off the request — the sync spins up a pi control session (a
    # Docker/gVisor container in prod), which 504s if done inline.
    RefreshModelCatalogJob.perform_later
    redirect_to models_path,
      notice: t("flash.models.refresh.notice")
  end

  def update_provider
    LlmProvider.find(params[:id]).set_enabled!(boolean_param(params[:enabled]))
    redirect_to models_path
  end

  def update_model
    model = LlmModel.find(params[:id])
    model.update!(enabled: boolean_param(params[:enabled]))
    redirect_to models_path
  end
end
