require "test_helper"

class Routine
  class EventDispatcherTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      @user = User.create!(email: "ed-#{SecureRandom.hex(4)}@example.com", password: "password123")
      @team = @user.personal_team
    end

    def event(type, payload = {})
      WebhookEvent.new(team: @team, provider: :github, event_type: type, payload: payload)
    end

    def webhook_routine(**attrs)
      @team.routines.create!({
        user: @user, name: "R-#{SecureRandom.hex(2)}", prompt: "hi",
        trigger_source: :webhook, event_type: "pull_request.*", enabled: true
      }.merge(attrs))
    end

    test "fires every enabled matching routine" do
      webhook_routine(name: "A")
      webhook_routine(name: "B")
      webhook_routine(name: "Nope", event_type: "issues.opened")

      assert_difference -> { @team.conversations.count }, 2 do
        Routine::EventDispatcher.dispatch(event("pull_request.opened"))
      end
    end

    test "the fired conversation's prompt carries the event data" do
      webhook_routine(prompt: "Handle {{event_type}}")
      Routine::EventDispatcher.dispatch(event("pull_request.opened"))
      message = @team.conversations.last.messages.order(:id).first
      assert_equal "Handle pull_request.opened", message.content
    end

    test "skips a routine inside its cooldown" do
      routine = webhook_routine(trigger_config: { "cooldown_seconds" => 300 })
      routine.update_column(:last_run_at, 1.minute.ago)

      assert_no_difference -> { @team.conversations.count } do
        Routine::EventDispatcher.dispatch(event("pull_request.opened"))
      end
    end

    test "honors trigger_config conditions on the payload" do
      webhook_routine(trigger_config: { "conditions" => { "action" => "opened" } })

      assert_no_difference -> { @team.conversations.count } do
        Routine::EventDispatcher.dispatch(event("pull_request.opened", "action" => "closed"))
      end
      assert_difference -> { @team.conversations.count }, 1 do
        Routine::EventDispatcher.dispatch(event("pull_request.opened", "action" => "opened"))
      end
    end

    test "a saved webhook event enqueues the dispatch job" do
      assert_enqueued_with(job: RoutineDispatchJob) do
        WebhookEvent.create!(team: @team, provider: :github, event_type: "push", payload: {})
      end
    end
  end
end
