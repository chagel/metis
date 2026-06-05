# Stop a conversation's Daytona sandbox after its keep-warm window, ending
# compute billing while keeping the filesystem for the next resume.
# Runtime::Daytona#schedule_stop enqueues this with `wait:
# config.x.agent.daytona_keep_warm_seconds` instead of stopping inline, so the
# stop never holds the ChatJob worker or serialises with the next turn's resume.
#
# It is a no-op when the box is warm or in use: a follow-up turn bumps the
# conversation's latest message id (the freshness token) and flips
# #turn_in_progress?, so an earlier job for a since-reused box leaves it
# running. Daytona's autoStop is the backstop if this job is lost (e.g. the
# dev async adapter dropping it on restart).
class DaytonaStopJob < ApplicationJob
  queue_as :default

  discard_on ActiveJob::DeserializationError

  def perform(conversation_id, sandbox_id, turn_token)
    conversation = Conversation.find_by(id: conversation_id)
    return unless conversation
    # Box replaced/cleared, a newer turn is running, or a newer turn has used
    # it since this stop was scheduled — leave it for that turn.
    return if conversation.daytona_sandbox_id != sandbox_id
    return if conversation.turn_in_progress?
    return if conversation.messages.maximum(:id) != turn_token

    Agent::Runtime::Daytona.stop_sandbox(conversation, sandbox_id)
  end
end
