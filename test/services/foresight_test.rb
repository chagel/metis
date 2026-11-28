require "test_helper"

class ForesightTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @user = User.create!(email: "fs-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @team = @user.personal_team
    @routine = Foresight.ensure_for(@user, @team)
    @routine.update_columns(next_run_at: 1.minute.ago)
  end

  test "a quiet night is skipped but the schedule still advances" do
    assert_no_difference -> { @routine.conversations.count } do
      assert @routine.fire_scheduled!
    end
    assert @routine.reload.next_run_at.future?
  end

  test "an active direction or a goal memory gives it something to do" do
    assert_not Foresight.activity?(@routine)
    UserMemory.create!(user: @user, team: @team, content: "Ship P3", kind: :goal)
    assert Foresight.activity?(@routine)
  end

  test "ensure_for is idempotent" do
    assert_equal @routine, Foresight.ensure_for(@user, @team)
  end
end
