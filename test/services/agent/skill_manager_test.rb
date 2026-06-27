require "test_helper"

class Agent::SkillManagerTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "sm-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @team = @user.personal_team
    @project = @team.projects.create!(name: "Metis")
    @conversation = @user.conversations.create!(team: @team, project: @project)
    @enabled = @team.skills.create!(slug: "code-review", description: "review PRs", enabled: true, content_cache: "x")
    @disabled = @team.skills.create!(slug: "legacy", description: "old", enabled: false, content_cache: "x")
  end

  test "list returns every team skill including disabled ones" do
    skills = Agent::SkillManager.list(@conversation)
    slugs = skills.map { |s| s[:slug] }

    assert_includes slugs, "code-review"
    assert_includes slugs, "legacy"
    legacy = skills.find { |s| s[:slug] == "legacy" }
    assert_equal false, legacy[:enabled]
    assert_equal "old", legacy[:description]
  end

  test "list is team-scoped" do
    other = User.create!(email: "sm-o-#{SecureRandom.hex(4)}@example.com", password: "password123").personal_team
    other.skills.create!(slug: "secret", content_cache: "x")

    refute_includes Agent::SkillManager.list(@conversation).map { |s| s[:slug] }, "secret"
  end

  test "set_enabled toggles a skill and returns ok" do
    result = Agent::SkillManager.set_enabled(@conversation, "slug" => "legacy", "enabled" => true)

    assert result[:ok]
    assert_equal "legacy", result[:slug]
    assert_equal true, result[:enabled]
    assert @disabled.reload.enabled?
  end

  test "set_enabled matches slug case-insensitively" do
    result = Agent::SkillManager.set_enabled(@conversation, "slug" => "Code-Review", "enabled" => false)
    assert result[:ok]
    refute @enabled.reload.enabled?
  end

  test "delete removes the skill row" do
    result = nil
    assert_difference -> { Skill.count }, -1 do
      result = Agent::SkillManager.delete(@conversation, "slug" => "legacy")
    end
    assert result[:ok]
    assert_equal "legacy", result[:slug]
    assert_nil Skill.find_by(id: @disabled.id)
  end

  test "errors for an unknown skill" do
    result = Agent::SkillManager.set_enabled(@conversation, "slug" => "ghost", "enabled" => true)
    refute result[:ok]
    assert_match(/no skill named "ghost"/i, result[:error])
  end

  test "refuses writes for a non-admin member" do
    member = User.create!(email: "sm-m-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @team.memberships.create!(user: member, role: :member)
    convo = member.conversations.create!(team: @team, project: @project)

    result = nil
    assert_no_difference -> { Skill.count } do
      result = Agent::SkillManager.delete(convo, "slug" => "legacy")
    end
    refute result[:ok]
    assert_match(/team admins/i, result[:error])
  end

  test "refuses writes from inside a workflow run" do
    run = WorkflowRun.start(
      team: @team, user: @user, project: @project,
      steps: [ { "name" => "s", "prompt" => "p", "gate" => "auto" } ]
    )
    result = nil
    assert_no_difference -> { Skill.count } do
      result = Agent::SkillManager.delete(run.conversation, "slug" => "legacy")
    end
    refute result[:ok]
    assert_match(/inside a workflow run/i, result[:error])
  end
end
