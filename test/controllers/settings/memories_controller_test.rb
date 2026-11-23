require "test_helper"

class Settings::MemoriesControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = User.create!(email: "smc-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @team = @user.personal_team
    sign_in @user
  end

  def memory(**attrs)
    UserMemory.create!({ user: @user, team: @team, content: "prefers short answers", kind: :preference }.merge(attrs))
  end

  test "index groups memories and shows provenance" do
    memory
    memory(content: "no em dashes", kind: :correction, source: :stated, confidence: :high)
    get memories_path

    assert_response :success
    assert_select ".memory-group-title", text: "Preferences"
    assert_select ".memory-group-title", text: "Corrections"
    assert_select ".badge", text: /Inferred · low confidence/
    assert_select ".badge", text: /You said this/
  end

  test "index empty state" do
    get memories_path
    assert_select ".pane-empty"
  end

  test "update edits content" do
    m = memory
    patch memory_path(m), params: { user_memory: { content: "prefers very short answers" } }
    assert_equal "prefers very short answers", m.reload.content
  end

  test "confirm makes an inference stated (turbo_stream)" do
    m = memory
    patch confirm_memory_path(m), as: :turbo_stream
    assert_response :success
    assert m.reload.source_stated?
  end

  test "destroy removes one memory (turbo_stream)" do
    m = memory
    delete memory_path(m), as: :turbo_stream
    assert_response :success
    assert_not UserMemory.exists?(m.id)
  end

  test "clear removes every memory in the current team only" do
    memory
    other = Team.create!(name: "Work #{SecureRandom.hex(2)}")
    other.memberships.create!(user: @user, role: :member)
    kept = UserMemory.create!(user: @user, team: other, content: "work fact", kind: :fact)

    delete clear_memories_path
    assert_redirected_to memories_path
    assert_equal 0, UserMemory.for(@user, @team).count
    assert UserMemory.exists?(kept.id)
  end

  test "another user's memory is not reachable" do
    stranger = User.create!(email: "x-#{SecureRandom.hex(4)}@example.com", password: "password123")
    theirs = UserMemory.create!(user: stranger, team: stranger.personal_team, content: "theirs", kind: :fact)

    delete memory_path(theirs)
    assert_response :not_found
    assert UserMemory.exists?(theirs.id)
  end
end
