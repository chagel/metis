require "test_helper"

class SkillTest < ActiveSupport::TestCase
  def team
    @team ||= Team.create!(name: "Acme")
  end

  def make_skill(**attrs)
    Skill.new({
      team: team, slug: "summarize", description: "Summarize a doc"
    }.merge(attrs))
  end

  test "a valid skill saves" do
    assert make_skill.save
  end

  test "slug is required" do
    assert_not make_skill(slug: nil).valid?
  end

  test "slug must be kebab-case" do
    assert_not make_skill(slug: "Has Spaces").valid?
    assert_not make_skill(slug: "-leading-dash").valid?
    assert_not make_skill(slug: "UPPER").valid?
    assert make_skill(slug: "rails-things").valid?
  end

  test "slug is unique per team" do
    make_skill.save!
    assert_not make_skill.valid?
  end

  test "slug cannot match a repo-shipped skill" do
    # Pick a slug that actually exists in .pi/skills/. If this list ever
    # changes the test will need to be updated, but at least one of
    # these is virtually certain to ship while the repo lives.
    repo_slug = Agent::Workspace.repo_slugs.first
    skip "repo has no skills checked in" if repo_slug.nil?

    skill = make_skill(slug: repo_slug)
    assert_not skill.valid?
    assert_includes skill.errors[:slug].join, "reserved"
  end

  test "two teams may share a slug" do
    make_skill.save!
    other = Team.create!(name: "Other")
    assert Skill.new(team: other, slug: "summarize", description: "x").valid?
  end

  test "enabled scope filters disabled rows" do
    on = make_skill.tap(&:save!)
    make_skill(slug: "off", enabled: false).save!
    assert_includes Skill.enabled, on
    assert_equal 1, Skill.enabled.count
  end

  test "replace_skill_md! attaches SKILL.md and mirrors to content_cache" do
    skill = make_skill.tap(&:save!)
    skill.replace_skill_md!("# Hello")
    skill.save!
    assert_equal "# Hello", skill.content_cache
    assert_equal [ "SKILL.md" ], skill.file_list
  end

  test "valid_file_path? accepts plain relative paths up to MAX_FILE_PATH_DEPTH" do
    assert Skill.valid_file_path?("notes.md")
    assert Skill.valid_file_path?("ref/style.md")
    assert Skill.valid_file_path?("scripts/build/run.sh")
  end

  test "valid_file_path? rejects unsafe paths" do
    refute Skill.valid_file_path?(nil)
    refute Skill.valid_file_path?("")
    refute Skill.valid_file_path?("SKILL.md")        # reserved
    refute Skill.valid_file_path?("/abs/path.md")    # absolute
    refute Skill.valid_file_path?("../escape.md")    # traversal
    refute Skill.valid_file_path?("has space.md")    # invalid segment
    refute Skill.valid_file_path?("a/b/c/d/e.md")    # too deep
    refute Skill.valid_file_path?("a" * 201 + ".md") # too long
  end

  test "replace_file! attaches a tree of files keyed by relative_path" do
    skill = make_skill.tap(&:save!)
    skill.replace_file!("SKILL.md", "# top")
    skill.replace_file!("scripts/run.sh", "#!/bin/sh\n", "text/x-shellscript")
    assert_equal [ "SKILL.md", "scripts/run.sh" ], skill.file_list
  end

  test "replace_file! rejects path traversal" do
    skill = make_skill.tap(&:save!)
    assert_raises(ArgumentError) { skill.replace_file!("../escape.md", "x") }
  end

  test "extract_to writes the tree to disk preserving relative paths" do
    skill = make_skill.tap(&:save!)
    skill.replace_skill_md!("# top")
    skill.replace_file!("scripts/run.sh", "#!/bin/sh\n", "text/x-shellscript")

    Dir.mktmpdir do |dir|
      skill.extract_to(dir)
      assert_equal "# top", File.read(File.join(dir, "SKILL.md"))
      assert_equal "#!/bin/sh\n", File.read(File.join(dir, "scripts/run.sh"))
    end
  end

  test "files can't overwrite someone else's private proposal, but its owner can revise it" do
    owner = User.create!(email: "own-#{SecureRandom.hex(4)}@example.com", password: "password123")
    teammate = User.create!(email: "mate-#{SecureRandom.hex(4)}@example.com", password: "password123")
    proposal = team.skills.create!(slug: "golf-progress", enabled: false, proposed_by: owner, content_cache: "original")
    files = { Skill::SKILL_MD => "---\nname: golf-progress\ndescription: changed\n---\n" }

    assert_raises(ActiveRecord::RecordInvalid) { Skill.upsert_from_files(team: team, slug: "golf-progress", files: files, by: teammate) }
    assert_equal "original", proposal.reload.content_cache

    Skill.upsert_from_files(team: team, slug: "golf-progress", files: files, by: owner)
    assert_equal "changed", proposal.reload.description
  end
end
