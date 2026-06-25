module Linear
  # Resolves the project of a Linear webhook delivery that referenced an
  # issue but carried no project of its own (Linear serializes a Comment's
  # issue shallowly, with no project). Looks the issue's project up via the
  # API and binds the row if the team has a project for it. Best-effort: a
  # missing token, an API error, or an unbound project all leave the row's
  # project nil.
  class ProjectBackfillJob < ApplicationJob
    queue_as :default

    def perform(webhook_event_id)
      event = WebhookEvent.find_by(id: webhook_event_id)
      return unless event&.linear? && event.project_id.nil?

      issue_id = Payload.issue_id(event.payload)
      return if issue_id.blank?

      token = bearer_for(event.team)
      return if token.blank?

      project_uuid = resolve_issue_project(token, issue_id)
      return if project_uuid.blank?

      project = event.team.projects.for_linear_project(project_uuid).first
      event.update_column(:project_id, project.id) if project
    rescue Linear::Api::Error => e
      Rails.logger.error("Linear::ProjectBackfillJob #{webhook_event_id}: #{e.class}: #{e.message}")
    end

    private

    def bearer_for(team)
      connector = team.connectors.find_by(catalog_key: "linear")
      return unless connector

      connector.connector_credentials.filter_map(&:linear_api_bearer).first
    end

    def resolve_issue_project(token, issue_id)
      Rails.cache.fetch("linear_issue_project/#{issue_id}", expires_in: 1.hour) do
        Linear::Api.new(token).issue_project_id(issue_id)
      end
    end
  end
end
