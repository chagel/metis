# Fans an inbound WebhookEvent out to the team's matching event routines.
# Enqueued from WebhookEvent#after_create_commit — the trigger half of the
# collect-then-trigger split (docs/routines.md, docs/workflows.md Phase 4).
class RoutineDispatchJob < ApplicationJob
  queue_as :default

  def perform(webhook_event_id)
    event = WebhookEvent.find_by(id: webhook_event_id)
    return unless event

    Routine::EventDispatcher.dispatch(event)
  end
end
