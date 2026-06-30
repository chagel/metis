require "test_helper"

class RoutineSchedulerJobTest < ActiveJob::TestCase
  setup do
    @user = User.create!(email: "rs-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @team = @user.personal_team
  end

  def routine(**attrs)
    @team.routines.create!({
      user: @user, name: "R-#{SecureRandom.hex(2)}", prompt: "hi",
      trigger_source: :schedule, cron: "0 9 * * *", timezone: "UTC"
    }.merge(attrs))
  end

  test "fires due routines and leaves future ones alone" do
    due = routine.tap { |r| r.update_column(:next_run_at, 1.minute.ago) }
    future = routine.tap { |r| r.update_column(:next_run_at, 1.hour.from_now) }

    assert_difference -> { @team.conversations.count }, 1 do
      RoutineSchedulerJob.perform_now
    end

    assert due.reload.next_run_at > Time.current
    assert future.reload.last_run_at.nil?
  end
end
