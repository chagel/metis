# Syncs the LLM catalog from pi off the web request — the sync spins up a pi
# control session (a Docker/gVisor container in prod), which blows past the
# proxy timeout if done inline (504). ModelCatalogSync logs and no-ops when
# pi is unreachable, so a failed run leaves the catalog untouched.
class RefreshModelCatalogJob < ApplicationJob
  queue_as :default

  def perform
    Agent::ModelCatalogSync.call
  end
end
