require "test_helper"

class SkillsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = User.create!(email: "sk-#{SecureRandom.hex(4)}@example.com", password: "password123")
    sign_in @user
  end

  def team = @user.personal_team

  def make_skill(**attrs)
    team.skills.create!({ slug: "summarize", description: "Summarize" }.merge(attrs))
  end

  test "index lists the team's skills" do
    make_skill
    get skills_path
    assert_response :success
    assert_select ".conn-list .conn-name", text: "summarize"
  end

  test "index empty state" do
    get skills_path
    assert_response :success
    assert_select ".pane-empty"
  end

  test "edit renders SKILL.md in the textarea" do
    skill = make_skill
    skill.replace_skill_md!("# Hello")
    skill.save!
    get edit_skill_path(skill)
    assert_response :success
    assert_select "textarea#skill_skill_md", text: /# Hello/
  end

  test "create writes the skill_md textarea through replace_skill_md!" do
    assert_difference -> { team.skills.count }, 1 do
      post skills_path, params: {
        skill: { slug: "summarize", description: "x", enabled: "1", skill_md: "# top" }
      }
    end
    skill = team.skills.find_by!(slug: "summarize")
    assert_redirected_to edit_skill_path(skill)
    assert_equal "# top", skill.content_cache
    assert_equal current_user_id, skill.created_by_id
  end

  test "create with invalid slug re-renders the form" do
    post skills_path, params: { skill: { slug: "Bad Slug", description: "x" } }
    assert_response :unprocessable_entity
    assert_select ".flash.error"
  end

  test "update edits an existing skill" do
    skill = make_skill
    patch skill_path(skill), params: { skill: { description: "Updated", skill_md: "# new" } }
    skill.reload
    assert_equal "Updated", skill.description
    assert_equal "# new", skill.content_cache
  end

  test "destroy deletes the skill" do
    skill = make_skill
    assert_difference -> { team.skills.count }, -1 do
      delete skill_path(skill)
    end
    assert_redirected_to skills_path
  end

  test "another team's skills are not accessible" do
    other = Team.create!(name: "Other")
    foreign = other.skills.create!(slug: "secret", description: "x")
    get edit_skill_path(foreign)
    assert_response :not_found
  end

  test "index defaults to the team tab" do
    make_skill(slug: "demo")
    get skills_path
    assert_response :success
    assert_select ".skills-tab.is-active", text: "Your skills"
    assert_select ".conn-name", text: "demo"
  end

  test "index built-in tab lists repo skills" do
    repo = [ Agent::RepoSkills::Listing.new(slug: "system-one", name: "system-one", description: "Built in skill.") ]
    with_stub(Agent::RepoSkills, :all, -> { repo }) do
      get skills_path(tab: "builtin")
    end
    assert_response :success
    assert_select ".skills-tab.is-active", text: "Built-in"
    assert_select ".conn-name", text: "system-one"
    assert_select ".badge", text: "Built-in"
  end

  test "index marketplace tab lists featured entries and marks installed ones" do
    # Skip the repo-slug guard so an existing skill at a featured slug can be created.
    with_stub(Agent::Workspace, :repo_slugs, -> { Set.new }) do
      make_skill(slug: "pdf") # collides with FEATURED pdf entry
      get skills_path(tab: "marketplace")
    end
    assert_response :success
    assert_select ".skills-tab.is-active", text: "Marketplace"
    assert_select "form[action=?]", import_skills_path, minimum: 1
    # The pdf entry should show "Installed" instead of the Install button
    assert_select ".badge", text: "Installed"
  end

  test "import_form renders the URL input page" do
    get import_form_skills_path
    assert_response :success
    assert_select "form[action=?]", import_skills_path
    assert_select "input[name='url']"
  end

  test "import enqueues ImportSkillJob and redirects with a pending notice" do
    assert_enqueued_with(job: ImportSkillJob,
                         args: [ { team_id: team.id, by_user_id: @user.id, url: "acme/skills/imported" } ]) do
      post import_skills_path, params: { url: "acme/skills/imported" }
    end
    assert_redirected_to skills_path
    assert_match(/Importing imported/, flash[:notice])
  end

  test "import rejects a blank URL without enqueueing a job" do
    assert_no_enqueued_jobs only: ImportSkillJob do
      post import_skills_path, params: { url: "" }
    end
    assert_redirected_to skills_path
    assert_match(/Paste a GitHub URL/, flash[:alert])
  end

  # --- supporting files ---------------------------------------------

  test "add_file attaches a supporting file" do
    skill = make_skill
    upload = fixture_file_upload(make_file("hello, world\n"), "text/plain")

    assert_difference -> { skill.files.reload.count }, 1 do
      post add_file_skill_path(skill), params: { path: "notes.txt", file: upload }
    end
    assert_redirected_to edit_skill_path(skill)
    assert_includes skill.files.map { |f| skill.relative_path(f) }, "notes.txt"
  end

  test "add_file rejects an unsafe path" do
    skill = make_skill
    upload = fixture_file_upload(make_file("x"), "text/plain")

    assert_no_difference -> { skill.files.reload.count } do
      post add_file_skill_path(skill), params: { path: "../escape.md", file: upload }
    end
    assert_redirected_to edit_skill_path(skill)
    assert_match(/Invalid path/, flash[:alert])
  end

  test "add_file rejects a file larger than MAX_FILE_SIZE" do
    skill = make_skill
    big = make_file("X" * (Skill::MAX_FILE_SIZE + 1))
    upload = fixture_file_upload(big, "application/octet-stream")

    post add_file_skill_path(skill), params: { path: "big.bin", file: upload }
    assert_redirected_to edit_skill_path(skill)
    assert_match(/too large/i, flash[:alert])
  end

  test "destroy_file purges the attachment" do
    skill = make_skill
    skill.replace_file!("ref/style.md", "tone: terse")
    skill.save!
    attachment = skill.files.find { |f| skill.relative_path(f) == "ref/style.md" }

    assert_difference -> { skill.files.reload.count }, -1 do
      delete destroy_file_skill_path(skill, file_id: attachment.id)
    end
  end

  test "download_file streams the blob bytes inline" do
    skill = make_skill
    skill.replace_file!("ref/style.md", "tone: terse", "text/markdown")
    skill.save!
    attachment = skill.files.find { |f| skill.relative_path(f) == "ref/style.md" }

    get download_file_skill_path(skill, file_id: attachment.id)
    assert_response :success
    assert_equal "tone: terse", response.body
    assert_match %r{\Atext/markdown}, response.content_type
  end

  test "download_file 404s on a missing attachment id" do
    skill = make_skill
    get download_file_skill_path(skill, file_id: 999_999)
    assert_response :not_found
  end

  private

  # Active Storage's fixture_file_upload wants a path; this writes
  # `content` to a per-test tempfile under tmp/ and returns its path.
  def make_file(content)
    path = Rails.root.join("tmp/test_uploads", "#{SecureRandom.hex(4)}.bin")
    FileUtils.mkdir_p(path.dirname)
    File.binwrite(path, content)
    path.to_s
  end


  def current_user_id = @user.id

  test "a proposed skill shows only to the user it was proposed for" do
    shared = Team.create!(name: "Shared #{SecureRandom.hex(2)}")
    shared.memberships.create!(user: @user, role: :admin)
    teammate = User.create!(email: "sk2-#{SecureRandom.hex(4)}@example.com", password: "password123")
    shared.memberships.create!(user: teammate, role: :admin)
    proposal = shared.skills.create!(slug: "investor-update", enabled: false, proposed_by: @user)

    post switch_team_path(shared)
    get skills_path
    assert_select ".conn-name", text: "investor-update"
    assert_select ".skill-badge.proposed"

    sign_in teammate
    post switch_team_path(shared)
    get skills_path
    assert_select ".conn-name", text: "investor-update", count: 0
    get edit_skill_path(proposal)
    assert_response :not_found
  end
end
