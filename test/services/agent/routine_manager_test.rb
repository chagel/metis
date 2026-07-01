require "test_helper"

module Agent
  class RoutineManagerTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "rm-#{SecureRandom.hex(4)}@example.com", password: "password123")
      @team = @user.personal_team
      @conversation = @user.conversations.create!(team: @team)
    end

    def create(params)
      Agent::RoutineManager.create(@conversation, params)
    end

    test "create makes a disabled schedule routine by default" do
      result = create("name" => "Digest", "prompt" => "summarize", "trigger" => "schedule",
                      "cron" => "0 9 * * *", "timezone" => "UTC")

      assert result[:ok]
      routine = @team.routines.named("Digest").first
      assert_not routine.enabled?
      assert routine.schedule?
    end

    test "create rejects an unknown trigger" do
      result = create("name" => "X", "prompt" => "p", "trigger" => "telepathy")
      assert_not result[:ok]
      assert_match(/Trigger must be one of/, result[:error])
    end

    test "create surfaces validation errors" do
      result = create("name" => "Bad", "prompt" => "p", "trigger" => "schedule", "cron" => "nonsense")
      assert_not result[:ok]
      assert_match(/cron/i, result[:error])
    end

    test "update changes fields and toggles enabled by name" do
      create("name" => "Digest", "prompt" => "p", "trigger" => "schedule", "cron" => "0 9 * * *")
      result = Agent::RoutineManager.update(@conversation, "name" => "Digest", "enabled" => true, "prompt" => "new")

      assert result[:ok]
      routine = @team.routines.named("Digest").first
      assert routine.enabled?
      assert_equal "new", routine.prompt
    end

    test "create stores an explicit model in run settings" do
      # No catalog synced in test → Agent::ModelSelection passes the value
      # through (pi validates it), storing it in trigger_config settings.
      create("name" => "Digest", "prompt" => "p", "trigger" => "schedule",
             "cron" => "0 9 * * *", "model" => "anthropic/claude-opus-4-8")
      routine = @team.routines.named("Digest").first
      assert_equal "anthropic/claude-opus-4-8", routine.run_settings["model"]
    end

    test "list returns the team's routines" do
      create("name" => "Digest", "prompt" => "p", "trigger" => "schedule", "cron" => "0 9 * * *")
      row = Agent::RoutineManager.list(@conversation).find { |r| r[:name] == "Digest" }
      assert_equal "schedule", row[:trigger]
      assert_not row[:enabled]
    end

    test "a non-admin member is refused" do
      other_team = Team.create!(name: "Acme")
      other_team.memberships.create!(user: @user, role: :member)
      conversation = @user.conversations.create!(team: other_team)

      result = Agent::RoutineManager.create(conversation, "name" => "X", "prompt" => "p", "trigger" => "schedule", "cron" => "0 9 * * *")
      assert_not result[:ok]
      assert_match(/admin/i, result[:error])
    end

    test "refused from inside a workflow run" do
      with_stub(@conversation, :workflow_run, -> { Object.new }) do
        result = create("name" => "X", "prompt" => "p", "trigger" => "schedule", "cron" => "0 9 * * *")
        assert_not result[:ok]
        assert_match(/workflow run/i, result[:error])
      end
    end
  end
end
