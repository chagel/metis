require "test_helper"

class RoutineTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @user = User.create!(email: "rt-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @team = @user.personal_team
  end

  def build_routine(**attrs)
    @team.routines.new({
      user: @user, name: "Standup", prompt: "Hi", trigger_source: :schedule,
      cron: "0 9 * * *", timezone: "UTC"
    }.merge(attrs))
  end

  test "a schedule routine requires a cron expression" do
    routine = build_routine(cron: nil)
    assert_not routine.valid?
    assert_includes routine.errors[:cron], "can't be blank"
  end

  test "a webhook routine requires an event_type" do
    routine = build_routine(trigger_source: :webhook, cron: nil, event_type: nil)
    assert_not routine.valid?
    assert_includes routine.errors[:event_type], "can't be blank"
  end

  test "an unparseable cron is rejected" do
    assert_not build_routine(cron: "not a cron").valid?
  end

  test "an unknown timezone is rejected" do
    assert_not build_routine(timezone: "Mars/Olympus").valid?
  end

  test "a cron carrying a timezone field is rejected" do
    # next_cron_time appends the zone as the 6th field, so a 6-field cron would
    # become unparseable there and silently never fire.
    assert_not build_routine(cron: "0 9 * * * America/New_York").valid?
  end

  test "saving a schedule routine computes next_run_at in its timezone" do
    routine = build_routine(cron: "0 9 * * *", timezone: "America/New_York")
    routine.save!
    # 9am New York is 13:00 or 14:00 UTC depending on DST — never 09:00 UTC.
    assert_not_equal 9, routine.next_run_at.hour
    assert routine.next_run_at > Time.current
  end

  test "a webhook routine has no next_run_at" do
    routine = build_routine(trigger_source: :webhook, cron: nil, event_type: "push")
    routine.save!
    assert_nil routine.next_run_at
  end

  test "due scope selects enabled schedule routines past their next_run_at" do
    due = build_routine(name: "Due").tap { |r| r.save!; r.update_column(:next_run_at, 1.minute.ago) }
    build_routine(name: "Future").tap { |r| r.save!; r.update_column(:next_run_at, 1.hour.from_now) }
    build_routine(name: "Off", enabled: false).tap { |r| r.save!; r.update_column(:next_run_at, 1.minute.ago) }

    assert_equal [ due.id ], Routine.due.pluck(:id)
  end

  test "matches_event handles exact and wildcard event types" do
    routine = build_routine(trigger_source: :webhook, cron: nil, event_type: "pull_request.*")
    routine.save!

    assert routine.matches_event?(WebhookEvent.new(team: @team, provider: :github, event_type: "pull_request.opened"))
    assert_not routine.matches_event?(WebhookEvent.new(team: @team, provider: :github, event_type: "issues.opened"))

    exact = build_routine(name: "Exact", trigger_source: :webhook, cron: nil, event_type: "push")
    exact.save!
    assert exact.matches_event?(WebhookEvent.new(team: @team, provider: :github, event_type: "push"))
    assert_not exact.matches_event?(WebhookEvent.new(team: @team, provider: :github, event_type: "pusher"))
  end

  test "within_cooldown is true only inside the cooldown window" do
    routine = build_routine(trigger_config: { "cooldown_seconds" => 300 })
    routine.save!
    assert_not routine.within_cooldown?

    routine.update_column(:last_run_at, 1.minute.ago)
    assert routine.within_cooldown?

    routine.update_column(:last_run_at, 10.minutes.ago)
    assert_not routine.within_cooldown?
  end

  test "fire! starts a turn in a fresh conversation and stamps last_run_at" do
    routine = build_routine
    routine.save!

    conversation = nil
    assert_difference -> { @user.conversations.count }, 1 do
      assert_enqueued_with(job: ChatJob) do
        conversation = routine.fire!
      end
    end

    assert_equal routine, conversation.routine
    assert_equal @user, conversation.user
    assert_equal "user", conversation.messages.order(:id).first.role
    assert_not_nil routine.reload.last_run_at
  end

  test "fire_scheduled! fires a due routine and advances next_run_at" do
    routine = build_routine
    routine.save!
    routine.update_column(:next_run_at, 1.minute.ago)

    assert routine.fire_scheduled!
    assert routine.reload.next_run_at > Time.current
  end

  test "fire_scheduled! is a no-op when not yet due" do
    routine = build_routine
    routine.save!
    routine.update_column(:next_run_at, 1.hour.from_now)

    assert_no_difference -> { @user.conversations.count } do
      assert_not routine.fire_scheduled!
    end
  end
end
