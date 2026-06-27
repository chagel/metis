require "test_helper"

class Agent::SkillManagerTest < ActiveSupport::TestCase
  SKILL_MD = <<~MD
    ---
    name: code-review
    description: review PRs
    ---

    # Code review
    Do the review.
  MD

  setup do
    @user = User.create!(email: "sm-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @team = @user.personal_team
    @project = @team.projects.create!(name: "Metis")
    @conversation = @user.conversations.create!(team: @team, project: @project)
  end

  test "list includes built-in repo skills and team skills, each with status" do
    @team.skills.create!(slug: "team-thing", description: "ours", enabled: false, content_cache: "x")
    skills = Agent::SkillManager.list(@conversation)

    builtin = skills.select { |s| s[:source] == "builtin" }
    assert builtin.any?, "repo skills should be listed"
    assert_equal "built-in", builtin.first[:status]

    team = skills.find { |s| s[:slug] == "team-thing" }
    assert_equal "team", team[:source]
    assert_equal "disabled", team[:status]
  end

  test "list marks an enabled team skill as enabled" do
    @team.skills.create!(slug: "team-thing", enabled: true, content_cache: "x")
    team = Agent::SkillManager.list(@conversation).find { |s| s[:slug] == "team-thing" }
    assert_equal "enabled", team[:status]
  end

  test "list is team-scoped for team skills" do
    other = User.create!(email: "sm-o-#{SecureRandom.hex(4)}@example.com", password: "password123").personal_team
    other.skills.create!(slug: "secret", content_cache: "x")
    slugs = Agent::SkillManager.list(@conversation).select { |s| s[:source] == "team" }.map { |s| s[:slug] }
    refute_includes slugs, "secret"
  end

  test "create makes a team skill from SKILL.md and parses the description" do
    result = nil
    assert_difference -> { Skill.count }, 1 do
      result = Agent::SkillManager.create(@conversation, "slug" => "code-review", "content" => SKILL_MD)
    end
    assert result[:ok]
    assert_equal "created", result[:action]
    skill = @team.skills.find_by(slug: "code-review")
    assert_equal "review PRs", skill.description
    assert skill.enabled?
  end

  test "create rejects a duplicate slug, steering to update" do
    @team.skills.create!(slug: "code-review", content_cache: "x")
    result = nil
    assert_no_difference -> { Skill.count } do
      result = Agent::SkillManager.create(@conversation, "slug" => "code-review", "content" => SKILL_MD)
    end
    refute result[:ok]
    assert_match(/already exists/i, result[:error])
  end

  test "create requires content" do
    result = Agent::SkillManager.create(@conversation, "slug" => "code-review")
    refute result[:ok]
    assert_match(/SKILL\.md content/i, result[:error])
  end

  test "create validates the skill before attaching SKILL.md" do
    result = nil
    assert_no_difference -> { ActiveStorage::Blob.count } do
      assert_no_difference -> { Skill.count } do
        result = Agent::SkillManager.create(@conversation, "slug" => "Bad Slug", "content" => SKILL_MD)
      end
    end

    refute result[:ok]
    assert_match(/Slug/i, result[:error])
  end

  test "create rejects a slug reserved by a built-in skill" do
    reserved = Agent::RepoSkills.all.first&.slug
    skip "no repo skills present" unless reserved

    result = Agent::SkillManager.create(@conversation, "slug" => reserved, "content" => SKILL_MD)
    refute result[:ok]
  end

  test "update replaces content and toggles enabled" do
    skill = @team.skills.create!(slug: "code-review", enabled: true, content_cache: "old")
    result = Agent::SkillManager.update(@conversation, "slug" => "code-review", "content" => SKILL_MD, "enabled" => false)

    assert result[:ok]
    assert_equal "updated", result[:action]
    skill.reload
    refute skill.enabled?
    assert_equal "review PRs", skill.description
  end

  test "update can toggle enabled alone, leaving content" do
    skill = @team.skills.create!(slug: "code-review", enabled: true, content_cache: "keep")
    Agent::SkillManager.update(@conversation, "slug" => "code-review", "enabled" => false)
    refute skill.reload.enabled?
    assert_equal "keep", skill.content_cache
  end

  test "update errors for an unknown team skill" do
    result = Agent::SkillManager.update(@conversation, "slug" => "ghost", "enabled" => false)
    refute result[:ok]
    assert_match(/no team skill named "ghost"/i, result[:error])
  end

  test "refuses writes for a non-admin member" do
    member = User.create!(email: "sm-m-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @team.memberships.create!(user: member, role: :member)
    convo = member.conversations.create!(team: @team, project: @project)

    result = nil
    assert_no_difference -> { Skill.count } do
      result = Agent::SkillManager.create(convo, "slug" => "code-review", "content" => SKILL_MD)
    end
    refute result[:ok]
    assert_match(/team admins/i, result[:error])
  end

  test "refuses writes from inside a workflow run" do
    run = WorkflowRun.start(
      team: @team, user: @user, project: @project,
      steps: [ { "name" => "s", "prompt" => "p", "gate" => "auto" } ]
    )
    result = Agent::SkillManager.create(run.conversation, "slug" => "code-review", "content" => SKILL_MD)
    refute result[:ok]
    assert_match(/inside a workflow run/i, result[:error])
  end
end
