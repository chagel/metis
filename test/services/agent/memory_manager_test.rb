require "test_helper"

module Agent
  class MemoryManagerTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "mm-#{SecureRandom.hex(4)}@example.com", password: "password123")
      @team = @user.personal_team
      @conversation = @user.conversations.create!(team: @team)
    end

    def remember(params) = Agent::MemoryManager.remember(@conversation, params)

    test "remember records an inferred, low-confidence memory by default" do
      result = remember("content" => "prefers tables when comparing", "kind" => "experience")

      assert result[:ok]
      memory = UserMemory.find(result[:id])
      assert_equal "prefers tables when comparing", memory.content
      assert memory.source_inferred?
      assert memory.confidence_low?
      assert_equal @conversation, memory.source_conversation
    end

    test "a stated memory defaults to high confidence" do
      result = remember("content" => "no em dashes", "kind" => "correction", "source" => "stated")
      assert_equal "high", result[:confidence]
    end

    test "remember rejects an unknown kind" do
      result = remember("content" => "x", "kind" => "vibe")
      assert_not result[:ok]
      assert_match(/Kind must be one of/, result[:error])
    end

    test "update and forget act only on this user's memories in this team" do
      own = UserMemory.create!(user: @user, team: @team, content: "uses Go", kind: :fact)
      other_user = User.create!(email: "mm2-#{SecureRandom.hex(4)}@example.com", password: "password123")
      theirs = UserMemory.create!(user: other_user, team: other_user.personal_team, content: "theirs", kind: :fact)

      assert Agent::MemoryManager.update(@conversation, "id" => own.id, "confidence" => "medium")[:ok]
      assert own.reload.confidence_medium?

      refused = Agent::MemoryManager.forget(@conversation, "id" => theirs.id)
      assert_not refused[:ok]
      assert UserMemory.exists?(theirs.id)

      assert Agent::MemoryManager.forget(@conversation, "id" => own.id)[:ok]
      assert_not UserMemory.exists?(own.id)
    end

    test "note_applied stamps last_applied_at on this user's memories only" do
      own = UserMemory.create!(user: @user, team: @team, content: "short answers", kind: :preference)
      result = Agent::MemoryManager.note_applied(@conversation, "ids" => [ own.id, 999_999 ])

      assert_equal 1, result[:noted]
      assert own.reload.last_applied_at.present?
    end

    test "memory is unavailable inside a workflow run" do
      project = @team.projects.create!(name: "P")
      workflow = @team.workflows.create!(name: "W", steps: [ { "name" => "s", "prompt" => "p", "gate" => "auto", "run" => "cloud" } ])
      run = WorkflowRun.start(team: @team, user: @user, project: project, workflow: workflow, input: "go", autostart: false)

      result = Agent::MemoryManager.remember(run.conversation, "content" => "x", "kind" => "fact")
      assert_not result[:ok]
      assert_match(/isn't available/, result[:error])
    end

    test "memory is unavailable once the user has left the team" do
      team = Team.create!(name: "Gone #{SecureRandom.hex(2)}")
      conversation = @user.conversations.create!(team: team)

      result = Agent::MemoryManager.remember(conversation, "content" => "x", "kind" => "fact")
      assert_not result[:ok]
      assert_not UserMemory.for(@user, team).exists?
    end

    test "new wording resets provenance to inferred from this conversation" do
      earlier = @user.conversations.create!(team: @team)
      memory = UserMemory.create!(user: @user, team: @team, content: "no em dashes", kind: :correction,
                                  source: :stated, confidence: :high, source_conversation: earlier)

      result = Agent::MemoryManager.update(@conversation, "id" => memory.id, "content" => "no dashes of any kind")

      assert result[:ok]
      memory.reload
      assert memory.source_inferred?
      assert memory.confidence_low?
      assert_equal @conversation, memory.source_conversation
    end

    test "new wording the user stated stays stated" do
      memory = UserMemory.create!(user: @user, team: @team, content: "uses Go", kind: :fact, source: :inferred)
      Agent::MemoryManager.update(@conversation, "id" => memory.id, "content" => "uses Go and Rust", "source" => "stated")

      assert memory.reload.source_stated?
      assert memory.confidence_high?
    end

    test "a confidence-only update keeps provenance" do
      earlier = @user.conversations.create!(team: @team)
      memory = UserMemory.create!(user: @user, team: @team, content: "uses Go", kind: :fact,
                                  source: :stated, confidence: :medium, source_conversation: earlier)
      Agent::MemoryManager.update(@conversation, "id" => memory.id, "content" => "uses Go", "confidence" => "high")

      memory.reload
      assert memory.source_stated?
      assert memory.confidence_high?
      assert_equal earlier, memory.source_conversation
    end

    test "results don't echo the memory text" do
      result = remember("content" => "prefers tables", "kind" => "preference")
      assert_not result.key?(:content)
    end

    test "a team-visible conversation can't touch personal memories" do
      @conversation.update!(visibility: :team)
      fact = UserMemory.create!(user: @user, team: @team, content: "moving to Tokyo", kind: :fact)

      assert_not Agent::MemoryManager.forget(@conversation, "id" => fact.id)[:ok]
      assert UserMemory.exists?(fact.id)
    end
  end
end
