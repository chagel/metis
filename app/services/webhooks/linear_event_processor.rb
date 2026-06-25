# Maps one Linear webhook delivery to a WebhookEvent. The team comes from
# the connector the URL token already resolved (no installation lookup like
# GitHub); the project is the team's project bound to the event's Linear
# project. Deduped on the Linear-Delivery id, which is unique per delivery.
module Webhooks
  class LinearEventProcessor
    def initialize(connector:, delivery:, event:, payload:)
      @connector = connector
      @delivery = delivery
      @event = event
      @payload = payload
    end

    def call
      WebhookEvent.create_or_find_by!(provider: :linear, external_id: @delivery) do |row|
        row.team = @connector.team
        row.project = resolve_project
        row.event_type = event_type
        row.source_installation_id = @payload["organizationId"]
        row.payload = @payload
      end
    end

    private

    # Linear's entity type (Linear-Event header) plus the body action
    # ("Issue.create"); bare type when there's no action.
    def event_type
      action = @payload["action"].presence
      action ? "#{@event}.#{action}" : @event.to_s
    end

    def resolve_project
      id = linear_project_id
      return if id.blank?

      @connector.team.projects.for_linear_project(id).first
    end

    # Where the Linear project id sits depends on the entity: a Project
    # event *is* the project (data.id); everything else references it
    # (data.project.id or data.projectId).
    def linear_project_id
      data = @payload["data"] || {}
      return data["id"] if @event == "Project"

      data.dig("project", "id") || data["projectId"]
    end
  end
end
