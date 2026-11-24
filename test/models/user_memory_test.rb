require "test_helper"

class UserMemoryTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "um-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @team = @user.personal_team
  end

  def remember(content = "prefers short answers", **attrs)
    UserMemory.create!({ user: @user, team: @team, content: content, kind: :preference }.merge(attrs))
  end

  test "defaults to an inferred, low-confidence memory" do
    memory = remember
    assert memory.source_inferred?
    assert memory.confidence_low?
  end

  test "content is encrypted at rest" do
    memory = remember("backend engineer on payments")
    raw = UserMemory.connection.select_value("SELECT content FROM user_memories WHERE id = #{memory.id}")
    assert_not_includes raw, "backend engineer"
  end

  test "content is capped and required" do
    assert_not UserMemory.new(user: @user, team: @team, kind: :fact, content: "x" * 501).valid?
    assert_not UserMemory.new(user: @user, team: @team, kind: :fact, content: "  ").valid?
  end

  test "refuses a new memory past the per-user cap" do
    UserMemory::MAX_PER_USER.times { |i| remember("memory #{i}") }

    extra = UserMemory.new(user: @user, team: @team, kind: :fact, content: "one too many")
    assert_not extra.valid?
    assert_match(/update or forget one first/, extra.errors.full_messages.to_sentence)
  end

  test "confirm! makes an inference stated and high" do
    memory = remember
    memory.confirm!
    assert memory.reload.source_stated?
    assert memory.confidence_high?
  end

  test "memories are scoped to a user within a team" do
    other_team = Team.create!(name: "Work #{SecureRandom.hex(2)}")
    other_team.memberships.create!(user: @user, role: :member)
    remember("personal-team memory")

    assert_equal 1, UserMemory.for(@user, @team).count
    assert_equal 0, UserMemory.for(@user, other_team).count
  end

  test "leaving a team removes your memories there" do
    team = Team.create!(name: "Work #{SecureRandom.hex(2)}")
    membership = team.memberships.create!(user: @user, role: :member)
    UserMemory.create!(user: @user, team: team, content: "uses Linear", kind: :fact)

    membership.destroy
    assert_equal 0, UserMemory.for(@user, team).count
  end
end
