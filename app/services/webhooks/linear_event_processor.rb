# Maps one Linear webhook delivery to a WebhookEvent. The team is resolved
# from the payload's organizationId against a linear connector's stored
# org id; an event no team has claimed is dropped. The project is the
# team's project bound to the event's Linear project. Deduped on the
# Linear-Delivery id, which is unique per delivery.
module Webhooks
  class LinearEventProcessor
    def initialize(event:, delivery:, payload:)
      @event = event
      @delivery = delivery
      @payload = payload
    end

    def call
      team = resolve_team
      return unless team

      event = WebhookEvent.create_or_find_by!(provider: :linear, external_id: @delivery) do |row|
        row.team = team
        row.project = resolve_project(team)
        row.event_type = event_type
        row.source_installation_id = organization_id
        row.payload = @payload
      end

      enqueue_project_backfill(event)
      event
    end

    private

    # When a fresh delivery couldn't be bound to a project but references an
    # issue (e.g. a Comment, which Linear serializes without a project),
    # resolve it out-of-band via the Linear API.
    def enqueue_project_backfill(event)
      return unless event.previously_new_record? && event.project_id.nil?
      return if Linear::Payload.issue_id(@payload).blank?

      Linear::ProjectBackfillJob.perform_later(event.id)
    end

    def resolve_team
      return if organization_id.blank?

      Connector.for_linear_organization(organization_id).first&.team
    end

    def organization_id
      @payload["organizationId"]
    end

    # Linear's entity type (Linear-Event header) plus the body action
    # ("Issue.create"); bare type when there's no action.
    def event_type
      action = @payload["action"].presence
      action ? "#{@event}.#{action}" : @event.to_s
    end

    def resolve_project(team)
      id = linear_project_id
      return if id.blank?

      team.projects.for_linear_project(id).first
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
