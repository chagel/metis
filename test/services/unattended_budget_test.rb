require "test_helper"

class UnattendedBudgetTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @user = User.create!(email: "budget-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @routine = @user.personal_team.routines.create!(user: @user, name: "Nightly", prompt: "Go", cron: "0 9 * * *")
  end

  def with_limits(runs:, cost:)
    config = Rails.application.config.x.agent
    original = [ config.unattended_daily_runs, config.unattended_daily_cost ]
    config.unattended_daily_runs, config.unattended_daily_cost = runs, cost
    yield
  ensure
    config.unattended_daily_runs, config.unattended_daily_cost = original
  end

  test "a fire past the daily run limit is refused before its conversation exists" do
    with_limits(runs: 1, cost: 100) do
      @routine.fire!
      error = assert_raises(UnattendedBudget::Exceeded) { @routine.fire! }
      assert_match "1 unattended runs", error.message
    end
    assert_equal 1, @user.conversations.routines.count
  end

  test "a fire past the daily cost limit is refused" do
    with_limits(runs: 100, cost: 1) do
      @routine.fire!.messages.where(role: :assistant).update_all(cost: 1.5)
      assert_raises(UnattendedBudget::Exceeded) { @routine.fire! }
    end
  end

  test "runs older than the window don't count; chats never do" do
    with_limits(runs: 1, cost: 100) do
      @routine.fire!.update_columns(created_at: 25.hours.ago)
      @user.conversations.create!
      assert_nothing_raised { UnattendedBudget.new(@user).check! }
    end
  end

  test "an over-budget scheduled fire is skipped but still advances" do
    @routine.update_columns(next_run_at: 1.minute.ago)
    with_limits(runs: 0, cost: 100) do
      assert @routine.fire_scheduled!
    end
    assert_equal 0, @user.conversations.routines.count
    assert @routine.reload.next_run_at.future?
  end
end
