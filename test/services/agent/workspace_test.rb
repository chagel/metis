require "test_helper"

class Agent::WorkspaceTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @user = User.create!(email: "ws@example.com", password: "password123")
    @conversation = @user.conversations.create!
  end

  teardown do
    [ Agent::Workspace::SCRATCH_ROOT, Agent::Workspace::PERSISTENT_ROOT ].each do |root|
      FileUtils.rm_rf(root.join("u#{@user.id}"))
    end
  end

  test "scratch and persistent resolve to different roots" do
    assert_includes Agent::Workspace.scratch(@conversation).scope_dir.to_s, Agent::Workspace::SCRATCH_ROOT.to_s
    assert_includes Agent::Workspace.persistent(@conversation).scope_dir.to_s, Agent::Workspace::PERSISTENT_ROOT.to_s
    refute_equal Agent::Workspace::SCRATCH_ROOT, Agent::Workspace::PERSISTENT_ROOT
  end

  test "persistent root stays under tmp in test even if METIS_PERSISTENT_ROOT is set" do
    # The env override (for Docker-in-Docker path-identity) must never take
    # effect in test, or the suite's rm_rf teardowns could alias real data.
    assert_includes Agent::Workspace::PERSISTENT_ROOT.to_s, "tmp/agent_persistent_test"
  end

  test "evict_workspace! deletes workspace/ and keeps sessions/, idempotently" do
    workspace = Agent::Workspace.persistent(@conversation).ensure!
    File.write(workspace.session_dir.join("s.jsonl"), "{}")
    File.write(workspace.workspace_dir.join("wip.txt"), "agent file")

    workspace.evict_workspace!

    refute workspace.workspace_dir.exist?
    assert workspace.session_dir.join("s.jsonl").exist?
    assert_nothing_raised { workspace.evict_workspace! }
  end

  test "evict_workspace! unlinks a symlinked workspace without following it" do
    workspace = Agent::Workspace.persistent(@conversation)
    victim = Agent::Workspace::PERSISTENT_ROOT.join("u#{@user.id}", "victim")
    FileUtils.mkdir_p(victim)
    File.write(victim.join("keep.txt"), "keep")
    FileUtils.mkdir_p(workspace.scope_dir)
    File.symlink(victim, workspace.workspace_dir)

    workspace.evict_workspace!

    refute File.symlink?(workspace.workspace_dir)
    assert victim.join("keep.txt").exist?
  end

  test "destroy_scope! removes the whole scope from bare ids, idempotently" do
    workspace = Agent::Workspace.persistent(@conversation).ensure!
    File.write(workspace.session_dir.join("s.jsonl"), "{}")

    Agent::Workspace.destroy_scope!(user_id: @user.id, conversation_id: @conversation.id)

    refute workspace.scope_dir.exist?
    assert_nothing_raised do
      Agent::Workspace.destroy_scope!(user_id: @user.id, conversation_id: @conversation.id)
    end
  end

  test "destroy_scope! rejects ids that are not integers" do
    [ "7; rm -rf /", nil ].each do |bad|
      assert_raises(ArgumentError, TypeError) do
        Agent::Workspace.destroy_scope!(user_id: bad, conversation_id: @conversation.id)
      end
    end
  end

  test "scopes the session, workspace, and uploads dirs per user and conversation" do
    workspace = Agent::Workspace.scratch(@conversation)
    scope = Agent::Workspace::SCRATCH_ROOT.join("u#{@user.id}", "c#{@conversation.id}")

    assert_equal scope, workspace.scope_dir
    assert_equal scope.join("sessions"), workspace.session_dir
    assert_equal scope.join("workspace"), workspace.workspace_dir
    assert_equal scope.join("workspace", "uploads"), workspace.uploads_dir
  end

  test "ensure! creates the scope directories, leaving existing content" do
    workspace = Agent::Workspace.scratch(@conversation)
    workspace.ensure!
    File.write(workspace.workspace_dir.join("keep.rb"), "code")

    workspace.ensure!
    assert Dir.exist?(workspace.session_dir)
    assert Dir.exist?(workspace.uploads_dir)
    assert_equal "code", File.read(workspace.workspace_dir.join("keep.rb")), "existing content kept"
  end

  test "ensure! replaces a symlinked workspace directory without following it" do
    workspace = Agent::Workspace.scratch(@conversation)
    victim = workspace.scope_dir.join("victim")
    FileUtils.mkdir_p(victim)
    File.write(victim.join("keep.txt"), "keep")
    File.symlink(victim, workspace.workspace_dir)

    workspace.ensure!

    refute File.symlink?(workspace.workspace_dir)
    assert workspace.workspace_dir.directory?
    assert_equal "keep", File.read(victim.join("keep.txt"))
  end

  test "ensure! replaces a symlinked uploads directory without following it" do
    workspace = Agent::Workspace.scratch(@conversation).ensure!
    victim = workspace.scope_dir.join("victim")
    FileUtils.mkdir_p(victim)
    File.write(victim.join("keep.txt"), "keep")
    FileUtils.rm_r(workspace.uploads_dir)
    File.symlink(victim, workspace.uploads_dir)

    workspace.ensure!

    refute File.symlink?(workspace.uploads_dir)
    assert workspace.uploads_dir.directory?
    assert_equal "keep", File.read(victim.join("keep.txt"))
  end

  # An upload double whose filename is hostile — Active Storage already
  # sanitizes path separators, so a crafted name has to be injected here.
  class CraftedUpload
    def initialize(name, content)
      @name = name
      @content = content
    end

    def filename = @name

    def open
      yield StringIO.new(@content)
    end
  end

  test "stage_uploads basenames the filename so a crafted name cannot escape" do
    workspace = Agent::Workspace.scratch(@conversation)
    workspace.ensure!

    workspace.stage_uploads([ CraftedUpload.new("../escape.txt", "data") ])

    assert_equal "data", File.read(workspace.uploads_dir.join("escape.txt"))
    refute File.exist?(workspace.scope_dir.join("escape.txt")), "the crafted name did not escape"
  end

  test "stage_uploads removes stale atomic temp files before staging" do
    workspace = Agent::Workspace.scratch(@conversation).ensure!
    stale = workspace.uploads_dir.join(".data.txt-abandoned.tmp")
    File.write(stale, "partial upload")

    workspace.stage_uploads([])

    refute stale.exist?
  end

  test "stage_uploads replaces a symlink without writing through it" do
    workspace = Agent::Workspace.scratch(@conversation)
    workspace.ensure!
    victim = workspace.scope_dir.join("victim.txt")
    destination = workspace.uploads_dir.join("data.txt")
    File.write(victim, "keep")
    File.symlink(victim, destination)

    workspace.stage_uploads([ CraftedUpload.new("data.txt", "new upload") ])

    assert_equal "keep", File.read(victim)
    refute File.symlink?(destination)
    assert_equal "new upload", File.read(destination)
  end

  test "stage_mcp_config writes .mcp.json into the workspace root" do
    workspace = Agent::Workspace.scratch(@conversation)
    workspace.ensure!

    workspace.stage_mcp_config(%({"mcpServers":{}}))

    assert_equal %({"mcpServers":{}}), File.read(workspace.workspace_dir.join(".mcp.json"))
  end

  test "stage_mcp_config writes .mcp.json 0600 — it carries bearer tokens" do
    workspace = Agent::Workspace.scratch(@conversation)
    workspace.ensure!

    workspace.stage_mcp_config(%({"mcpServers":{}}))

    mode = File.stat(workspace.workspace_dir.join(".mcp.json")).mode & 0o777
    assert_equal 0o600, mode
  end

  test "stage_mcp_config replaces a symlink without writing through it" do
    workspace = Agent::Workspace.scratch(@conversation)
    workspace.ensure!
    victim = workspace.scope_dir.join("victim.json")
    destination = workspace.workspace_dir.join(".mcp.json")
    File.write(victim, "keep")
    File.symlink(victim, destination)

    workspace.stage_mcp_config(%({"mcpServers":{}}))

    assert_equal "keep", File.read(victim)
    refute File.symlink?(destination)
    assert_equal %({"mcpServers":{}}), File.read(destination)
    assert_equal 0o600, File.stat(destination).mode & 0o777
  end

  test "stage_mcp_config removes stale token-bearing temp files before staging" do
    workspace = Agent::Workspace.scratch(@conversation).ensure!
    stale = workspace.workspace_dir.join("..mcp.json-abandoned.tmp")
    File.write(stale, "old bearer token")

    workspace.stage_mcp_config(%({"mcpServers":{}}))

    refute stale.exist?
  end

  test "discard_mcp_config removes the token-bearing .mcp.json" do
    workspace = Agent::Workspace.scratch(@conversation)
    workspace.ensure!
    workspace.stage_mcp_config(%({"mcpServers":{}}))

    workspace.discard_mcp_config

    assert_not File.exist?(workspace.workspace_dir.join(".mcp.json"))
  end

  test "stage_identity writes AGENTS.md into the workspace root" do
    workspace = Agent::Workspace.scratch(@conversation)
    workspace.ensure!

    workspace.stage_identity("# Hello, pi")

    assert_equal "# Hello, pi", File.read(workspace.workspace_dir.join("AGENTS.md"))
  end

  test "stage_identity replaces a symlink without writing through it" do
    workspace = Agent::Workspace.scratch(@conversation)
    workspace.ensure!
    victim = workspace.scope_dir.join("victim.md")
    destination = workspace.workspace_dir.join("AGENTS.md")
    File.write(victim, "keep")
    File.symlink(victim, destination)

    workspace.stage_identity("# Hello, pi")

    assert_equal "keep", File.read(victim)
    refute File.symlink?(destination)
    assert_equal "# Hello, pi", File.read(destination)
  end

  test "stage_skills copies the repo's .pi/skills tree into workspace/.pi/skills" do
    workspace = Agent::Workspace.scratch(@conversation)
    workspace.ensure!

    with_skills_source do |source|
      FileUtils.mkdir_p(source.join("alpha/scripts"))
      File.write(source.join("alpha/SKILL.md"), "alpha")
      File.write(source.join("alpha/scripts/run.sh"), "#!/bin/sh\n")

      workspace.stage_skills
    end

    dest = workspace.workspace_dir.join(".pi/skills")
    assert_equal "alpha", File.read(dest.join("alpha/SKILL.md"))
    assert_equal "#!/bin/sh\n", File.read(dest.join("alpha/scripts/run.sh"))
  end

  test "stage_skills overwrites the prior turn's tree so deleted skills disappear" do
    workspace = Agent::Workspace.scratch(@conversation)
    workspace.ensure!
    FileUtils.mkdir_p(workspace.workspace_dir.join(".pi/skills/stale"))
    File.write(workspace.workspace_dir.join(".pi/skills/stale/SKILL.md"), "stale")

    with_skills_source do |source|
      FileUtils.mkdir_p(source.join("fresh"))
      File.write(source.join("fresh/SKILL.md"), "fresh")

      workspace.stage_skills
    end

    refute File.exist?(workspace.workspace_dir.join(".pi/skills/stale/SKILL.md"))
    assert_equal "fresh", File.read(workspace.workspace_dir.join(".pi/skills/fresh/SKILL.md"))
  end

  test "stage_skills is a no-op when the repo has no .pi/skills tree and no team skills" do
    workspace = Agent::Workspace.scratch(@conversation)
    workspace.ensure!

    with_skills_source(create: false) do
      workspace.stage_skills
    end

    refute File.exist?(workspace.workspace_dir.join(".pi/skills"))
  end

  test "stage_skills writes enabled team skills into .pi/skills/<slug>/ alongside repo skills" do
    workspace = Agent::Workspace.scratch(@conversation)
    workspace.ensure!

    skill = @conversation.team.skills.create!(slug: "summarize", description: "x")
    skill.replace_skill_md!("# team skill")
    skill.save!

    with_skills_source do |source|
      FileUtils.mkdir_p(source.join("alpha"))
      File.write(source.join("alpha/SKILL.md"), "# repo skill")
      workspace.stage_skills
    end

    dest = workspace.workspace_dir.join(".pi/skills")
    assert_equal "# repo skill", File.read(dest.join("alpha/SKILL.md"))
    assert_equal "# team skill", File.read(dest.join("summarize/SKILL.md"))
  end

  test "stage_skills skips re-staging when the signature marker matches" do
    workspace = Agent::Workspace.scratch(@conversation)
    workspace.ensure!

    with_skills_source do |source|
      FileUtils.mkdir_p(source.join("alpha"))
      File.write(source.join("alpha/SKILL.md"), "v1")
      workspace.stage_skills

      # Tamper with the staged tree: if the second stage skips, our
      # edit survives; if it wipes & re-copies, it reverts to "v1".
      tampered = workspace.workspace_dir.join(".pi/skills/alpha/SKILL.md")
      File.write(tampered, "tampered")
      workspace.stage_skills

      assert_equal "tampered", tampered.read
    end
  end

  test "stage_skills does not trust a symlinked signature marker" do
    workspace = Agent::Workspace.scratch(@conversation)
    workspace.ensure!

    with_skills_source do |source|
      FileUtils.mkdir_p(source.join("alpha"))
      File.write(source.join("alpha/SKILL.md"), "v1")
      workspace.stage_skills

      staged = workspace.skills_dir.join("alpha/SKILL.md")
      marker = workspace.skills_dir.join(Agent::Workspace::SKILLS_MARKER)
      forged_marker = workspace.scope_dir.join("forged.sig")
      File.write(staged, "tampered")
      File.write(forged_marker, File.read(marker))
      File.unlink(marker)
      File.symlink(forged_marker, marker)

      workspace.stage_skills

      assert_equal "v1", File.read(staged)
      refute File.symlink?(marker)
    end
  end

  test "stage_skills re-stages when the repo source changes" do
    workspace = Agent::Workspace.scratch(@conversation)
    workspace.ensure!

    with_skills_source do |source|
      FileUtils.mkdir_p(source.join("alpha"))
      File.write(source.join("alpha/SKILL.md"), "v1")
      workspace.stage_skills

      File.write(source.join("alpha/SKILL.md"), "v2 (different)")
      Agent::Workspace.reset_repo_skills_fingerprint!
      workspace.stage_skills

      assert_equal "v2 (different)",
        workspace.workspace_dir.join(".pi/skills/alpha/SKILL.md").read
    end
  end

  test "stage_skills re-stages when a team skill is updated" do
    workspace = Agent::Workspace.scratch(@conversation)
    workspace.ensure!
    skill = @conversation.team.skills.create!(slug: "drift", description: "x")
    skill.replace_skill_md!("first")
    skill.save!

    with_skills_source(create: false) { workspace.stage_skills }
    assert_equal "first",
      workspace.workspace_dir.join(".pi/skills/drift/SKILL.md").read

    travel 2.seconds do
      skill.replace_skill_md!("second")
      skill.save!
      with_skills_source(create: false) { workspace.stage_skills }
    end

    assert_equal "second",
      workspace.workspace_dir.join(".pi/skills/drift/SKILL.md").read
  end

  test "stage_skills skips disabled team skills" do
    workspace = Agent::Workspace.scratch(@conversation)
    workspace.ensure!

    skill = @conversation.team.skills.create!(slug: "off", description: "x", enabled: false)
    skill.replace_skill_md!("# hidden")
    skill.save!

    with_skills_source(create: false) { workspace.stage_skills }

    refute File.exist?(workspace.workspace_dir.join(".pi/skills/off"))
  end

  test "ingest_team_skills creates a Skill row from an agent-written dir" do
    workspace = Agent::Workspace.scratch(@conversation)
    workspace.ensure!
    write_skill_dir(workspace, "draft-pr", <<~MD, files: { "ref/style.md" => "tone: terse\n" })
      ---
      name: draft-pr
      description: Draft a PR description from a branch diff.
      ---

      # Body
    MD

    assert_difference -> { @conversation.team.skills.count }, 1 do
      workspace.ingest_team_skills(slugs: Set["draft-pr"], by: @user)
    end

    skill = @conversation.team.skills.find_by!(slug: "draft-pr")
    assert_equal "Draft a PR description from a branch diff.", skill.description
    assert_includes skill.content_cache, "# Body"
    assert_equal [ "SKILL.md", "ref/style.md" ].sort, skill.file_list
    assert_equal @user, skill.created_by
  end

  test "ingest_team_skills skips symlinked supporting files" do
    workspace = Agent::Workspace.scratch(@conversation)
    workspace.ensure!
    write_skill_dir(workspace, "safe-skill", <<~MD)
      ---
      name: safe-skill
      description: A safe skill.
      ---

      # Body
    MD
    secret = workspace.scope_dir.join("secret.txt")
    File.write(secret, "host secret")
    File.symlink(secret, workspace.skills_dir.join("safe-skill/secret.txt"))

    workspace.ingest_team_skills(slugs: Set["safe-skill"], by: @user)

    skill = @conversation.team.skills.find_by!(slug: "safe-skill")
    assert_equal [ "SKILL.md" ], skill.file_list
  end

  test "ingest_team_skills does not traverse a symlinked supporting directory" do
    workspace = Agent::Workspace.scratch(@conversation)
    workspace.ensure!
    write_skill_dir(workspace, "safe-skill", <<~MD)
      ---
      name: safe-skill
      description: A safe skill.
      ---

      # Body
    MD
    host_dir = workspace.scope_dir.join("host-files")
    FileUtils.mkdir_p(host_dir)
    File.write(host_dir.join("secret.txt"), "host secret")
    File.symlink(host_dir, workspace.skills_dir.join("safe-skill/references"))

    workspace.ingest_team_skills(slugs: Set["safe-skill"], by: @user)

    skill = @conversation.team.skills.find_by!(slug: "safe-skill")
    assert_equal [ "SKILL.md" ], skill.file_list
  end

  test "ingest_team_skills refuses a symlinked skills root" do
    workspace = Agent::Workspace.scratch(@conversation)
    workspace.ensure!
    host_skills = workspace.scope_dir.join("host-skills")
    host_skill = host_skills.join("escaped")
    FileUtils.mkdir_p(host_skill)
    File.write(host_skill.join("SKILL.md"), <<~MD)
      ---
      name: escaped
      description: Host-side skill.
      ---
    MD
    FileUtils.mkdir_p(workspace.skills_dir.dirname)
    File.symlink(host_skills, workspace.skills_dir)

    assert_no_difference -> { @conversation.team.skills.count } do
      workspace.ingest_team_skills(slugs: Set["escaped"], by: @user)
    end

    refute File.symlink?(workspace.skills_dir)
  end

  test "queue_skill_imports enqueues ImportSkillJob for each URL in the sentinel" do
    workspace = Agent::Workspace.scratch(@conversation)
    workspace.ensure!
    FileUtils.mkdir_p(workspace.skills_dir)
    File.write(workspace.skills_dir.join(".imports"), <<~TXT)
      anthropics/skills/skills/pdf
      # comment, skipped

      anthropics/skills/skills/xlsx
      anthropics/skills/skills/pdf
    TXT

    assert_enqueued_jobs 2, only: ImportSkillJob do
      workspace.queue_skill_imports(by: @user)
    end

    enqueued = ActiveJob::Base.queue_adapter.enqueued_jobs.last(2).map { |j| j[:args].first["url"] }
    assert_equal [ "anthropics/skills/skills/pdf", "anthropics/skills/skills/xlsx" ], enqueued
  end

  test "queue_skill_imports refuses a symlinked sentinel" do
    workspace = Agent::Workspace.scratch(@conversation)
    workspace.ensure!
    FileUtils.mkdir_p(workspace.skills_dir)
    source = workspace.scope_dir.join("imports.txt")
    File.write(source, "anthropics/skills/skills/pdf\n")
    File.symlink(source, workspace.skills_dir.join(".imports"))

    assert_no_enqueued_jobs only: ImportSkillJob do
      workspace.queue_skill_imports(by: @user)
    end
  end

  test "queue_skill_imports refuses an oversized sentinel" do
    workspace = Agent::Workspace.scratch(@conversation)
    workspace.ensure!
    FileUtils.mkdir_p(workspace.skills_dir)
    File.write(workspace.skills_dir.join(".imports"), "a" * (64.kilobytes + 1))

    assert_no_enqueued_jobs only: ImportSkillJob do
      workspace.queue_skill_imports(by: @user)
    end
  end

  test "queue_skill_imports is a no-op when the sentinel file is absent" do
    workspace = Agent::Workspace.scratch(@conversation)
    workspace.ensure!

    assert_no_enqueued_jobs only: ImportSkillJob do
      workspace.queue_skill_imports(by: @user)
    end
  end

  test "ingest_team_skills updates an existing Skill row" do
    workspace = Agent::Workspace.scratch(@conversation)
    workspace.ensure!
    existing = @conversation.team.skills.create!(slug: "draft-pr", description: "old")
    existing.replace_skill_md!("# old body")
    existing.save!

    write_skill_dir(workspace, "draft-pr", <<~MD)
      ---
      name: draft-pr
      description: New shape — lead with why.
      ---

      # new body
    MD

    workspace.ingest_team_skills(slugs: Set["draft-pr"], by: @user)

    existing.reload
    assert_equal "New shape — lead with why.", existing.description
    assert_includes existing.content_cache, "# new body"
  end

  test "ingest_team_skills skips dirs with no SKILL.md" do
    workspace = Agent::Workspace.scratch(@conversation)
    workspace.ensure!
    FileUtils.mkdir_p(workspace.skills_dir.join("no-skill-md"))
    File.write(workspace.skills_dir.join("no-skill-md/notes.txt"), "x")

    assert_no_difference -> { @conversation.team.skills.count } do
      workspace.ingest_team_skills(slugs: Set["no-skill-md"], by: @user)
    end
  end

  test "ingest_team_skills skips slugs that match a repo skill — repo tree stays read-only" do
    workspace = Agent::Workspace.scratch(@conversation)
    workspace.ensure!

    with_skills_source do |source|
      FileUtils.mkdir_p(source.join("writing-rails-code"))
      File.write(source.join("writing-rails-code/SKILL.md"), "# original")

      # Simulate the agent tampering: write a different SKILL.md into the
      # repo slug's dir inside the workspace tree.
      write_skill_dir(workspace, "writing-rails-code", "# tampered")

      assert_no_difference -> { @conversation.team.skills.count } do
        workspace.ingest_team_skills(slugs: Set["writing-rails-code"], by: @user)
      end
    end
  end

  test "ingest_team_skills skips invalid slugs" do
    workspace = Agent::Workspace.scratch(@conversation)
    workspace.ensure!
    write_skill_dir(workspace, "Has Spaces", "x")

    assert_no_difference -> { @conversation.team.skills.count } do
      workspace.ingest_team_skills(slugs: Set["Has Spaces"], by: @user)
    end
  end

  test "ingest_team_skills is a no-op when no slugs were touched" do
    workspace = Agent::Workspace.scratch(@conversation)
    workspace.ensure!
    write_skill_dir(workspace, "untouched", "# body")

    assert_no_difference -> { @conversation.team.skills.count } do
      workspace.ingest_team_skills(slugs: Set.new, by: @user)
    end
  end

  test "ingest_team_skills does NOT delete rows missing from the touched set" do
    workspace = Agent::Workspace.scratch(@conversation)
    workspace.ensure!
    @conversation.team.skills.create!(slug: "keeper", description: "x")

    assert_no_difference -> { @conversation.team.skills.count } do
      workspace.ingest_team_skills(slugs: Set["other"], by: @user)
    end
  end

  test "ingest_team_skills picks up supporting-file changes even when SKILL.md is unchanged" do
    workspace = Agent::Workspace.scratch(@conversation)
    workspace.ensure!

    # Seed an existing skill — same SKILL.md content the agent would
    # leave alone this turn, plus an old version of a supporting file.
    skill_md = "---\nname: rn\ndescription: release notes\n---\n# body\n"
    existing = @conversation.team.skills.create!(slug: "rn", description: "release notes")
    existing.replace_skill_md!(skill_md)
    existing.replace_file!("ref/style.md", "v1: short and concise")
    existing.save!

    # Agent edits ONLY the supporting file this turn.
    write_skill_dir(workspace, "rn", skill_md, files: { "ref/style.md" => "v2: punchy verbs only" })

    workspace.ingest_team_skills(slugs: Set["rn"], by: @user)

    existing.reload
    style = existing.files.find { |f| existing.relative_path(f) == "ref/style.md" }
    assert_equal "v2: punchy verbs only", style.download,
                 "supporting-file edit must reach the DB even when SKILL.md was untouched"
  end

  test "ingest_team_skill_from_files upserts from an in-memory map (E2b path)" do
    workspace = Agent::Workspace.scratch(@conversation)

    assert_difference -> { @conversation.team.skills.count }, 1 do
      workspace.ingest_team_skill_from_files(
        slug: "from-sandbox",
        files: {
          "SKILL.md" => "---\nname: from-sandbox\ndescription: built from a sandbox read.\n---\n\n# body\n",
          "ref/note.md" => "supplemental\n"
        },
        by: @user
      )
    end

    skill = @conversation.team.skills.find_by!(slug: "from-sandbox")
    assert_equal "built from a sandbox read.", skill.description
    assert_equal [ "SKILL.md", "ref/note.md" ].sort, skill.file_list
  end

  private

  def write_skill_dir(workspace, slug, body, files: {})
    dir = workspace.skills_dir.join(slug)
    FileUtils.mkdir_p(dir)
    File.write(dir.join("SKILL.md"), body)
    files.each do |rel, content|
      path = dir.join(rel)
      FileUtils.mkdir_p(path.dirname)
      File.write(path, content)
    end
  end

  # Point SKILLS_SOURCE at a tmp dir for the block. `create: false` skips
  # creating it, simulating an absent .pi/skills tree.
  def with_skills_source(create: true)
    Dir.mktmpdir do |tmp|
      source = Pathname.new(tmp).join("skills")
      FileUtils.mkdir_p(source) if create
      # Re-define the frozen constant for the duration of the test.
      original = Agent::Workspace::SKILLS_SOURCE
      Agent::Workspace.send(:remove_const, :SKILLS_SOURCE)
      Agent::Workspace.const_set(:SKILLS_SOURCE, source)
      Agent::Workspace.reset_repo_skills_fingerprint!
      begin
        yield source
      ensure
        Agent::Workspace.send(:remove_const, :SKILLS_SOURCE)
        Agent::Workspace.const_set(:SKILLS_SOURCE, original)
        Agent::Workspace.reset_repo_skills_fingerprint!
      end
    end
  end
end
