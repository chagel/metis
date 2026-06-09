# The deployment's LLM catalog under /settings — list providers/models,
# refresh from pi, and toggle availability. The page is readable by any
# member; mutations are superuser-only.
class ModelsController < ApplicationController
  layout "settings"

  before_action :require_superuser!, except: :index

  def index
    @providers = LlmProvider.ordered.includes(:llm_models)
  end

  def refresh
    # Run off the request — the sync spins up a pi control session (a
    # Docker/gVisor container in prod), which 504s if done inline.
    RefreshModelCatalogJob.perform_later
    redirect_to models_path,
      notice: "Refreshing the catalog from pi in the background — reload in a moment."
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
