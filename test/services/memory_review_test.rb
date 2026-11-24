require "test_helper"

class MemoryReviewTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "rv-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @team = @user.personal_team
  end

  def remember(content = "short answers") = UserMemory.create!(user: @user, team: @team, content: content, kind: :preference)

  test "the first memory creates one enabled nightly review routine" do
    remember
    remember("no em dashes")

    routine = MemoryReview.routine_for(@user, @team)
    assert routine.enabled?
    assert routine.memory_review?
    assert_equal MemoryReview::CRON, routine.cron
    assert routine.visibility_personal?
    assert_equal 1, @team.routines.count
  end

  test "teammates each get their own review under the same name" do
    team = Team.create!(name: "Acme")
    other = User.create!(email: "rv2-#{SecureRandom.hex(4)}@example.com", password: "password123")
    [ @user, other ].each do |user|
      team.memberships.create!(user: user, role: :member)
      UserMemory.create!(user: user, team: team, content: "uses Go", kind: :fact)
    end

    reviews = [ @user, other ].map { |user| MemoryReview.routine_for(user, team) }
    assert_equal [ MemoryReview::NAME ] * 2, reviews.map(&:name)
    assert_equal 2, reviews.uniq.size
  end

  test "the review's own edits don't make the next night active" do
    memory = remember
    routine = MemoryReview.routine_for(@user, @team)
    review = routine.conversations.create!(user: @user, team: @team)
    memory.update_columns(updated_at: 1.minute.ago)
    review.messages.create!(role: :assistant, content: "Raised one memory.", streaming_status: :done)

    assert_not MemoryReview.activity?(routine)
  end

  test "a failed review setup doesn't fail the memory" do
    with_stub(MemoryReview, :ensure_for, ->(*) { raise ActiveRecord::RecordInvalid }) do
      assert remember.persisted?
    end
  end

  test "a due review is skipped on a quiet night and fires when there's activity" do
    memory = remember
    routine = MemoryReview.routine_for(@user, @team)
    memory.update_columns(created_at: 2.days.ago, updated_at: 2.days.ago)
    routine.update_columns(last_run_at: 1.day.ago, next_run_at: 1.minute.ago)

    assert_no_difference -> { routine.conversations.count } do
      assert routine.fire_scheduled!
    end
    assert routine.reload.next_run_at > Time.current

    conversation = @user.conversations.create!(team: @team)
    conversation.messages.create!(role: :assistant, content: "ok", streaming_status: :done, applied_memory_ids: [ memory.id ])
    routine.update_columns(next_run_at: 1.minute.ago)

    assert_difference -> { routine.conversations.count }, 1 do
      routine.fire_scheduled!
    end
  end
end
