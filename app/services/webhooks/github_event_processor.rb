# Maps one GitHub App webhook delivery to a WebhookEvent. The team is
# resolved from the payload's installation id against a github connector's
# bot_installation_id; an event no team has claimed is dropped.
module Webhooks
  class GithubEventProcessor
    def initialize(event:, delivery:, payload:)
      @event = event
      @delivery = delivery
      @payload = payload
    end

    def call
      team = resolve_team
      return unless team

      WebhookEvent.create_or_find_by!(provider: :github, external_id: @delivery) do |row|
        row.team = team
        row.project = resolve_project(team)
        row.event_type = event_type
        row.source_installation_id = installation_id
        row.payload = @payload
      end
    end

    private

    def resolve_team
      return if installation_id.blank?

      Connector.where(catalog_key: "github")
               .where("settings ->> 'bot_installation_id' = ?", installation_id.to_s)
               .first&.team
    end

    # The team's project bound to this event's repo, or nil. Account-level
    # events (no repository block) and unbound repos resolve to nil.
    def resolve_project(team)
      full_name = @payload.dig("repository", "full_name")
      return if full_name.blank?

      team.projects.for_github_repo(full_name).first
    end

    def installation_id
      @payload.dig("installation", "id")
    end

    # GitHub's event name plus the payload action ("pull_request.opened");
    # bare event name when the payload carries no action ("push").
    def event_type
      action = @payload["action"].presence
      action ? "#{@event}.#{action}" : @event.to_s
    end
  end
end
