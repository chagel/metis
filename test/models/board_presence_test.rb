require "test_helper"

class BoardPresenceTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "pres-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @team = @user.personal_team
    @project = @team.projects.create!(name: "Cheese")
  end

  def add_member(**attrs)
    member = User.create!(email: "m-#{SecureRandom.hex(4)}@example.com", password: "password123", **attrs)
    @team.memberships.create!(user: member, role: :member)
    member
  end

  def awaiting_run(user: @user, visibility: :personal)
    conversation = user.conversations.create!(team: @team, project: @project, visibility: visibility)
    run = @team.workflow_runs.create!(conversation: conversation, status: :awaiting_approval)
    run.tasks.create!(position: 0, gate: :approval, status: :awaiting_approval, name: "review")
    run
  end

  test "people attribute a gate to the run launcher and sort gated first" do
    gated = add_member
    add_member # idle member
    awaiting_run(user: gated, visibility: :team)

    people = BoardPresence.for(team: @team, user: @user).people
    gated_person = people.find { |person| person.member == gated }

    assert_equal 1, gated_person.gate_count
    refute gated_person.idle?
    assert_match(/-/, gated_person.gate_ref)
    assert_equal gated_person, people.first, "gated members sort first"
    assert people.last.idle?, "idle members sort last"
  end

  test "a teammate's personal awaiting run does not leak as a gate" do
    other = add_member
    awaiting_run(user: other, visibility: :personal)

    person = BoardPresence.for(team: @team, user: @user).people.find { |p| p.member == other }
    assert person.idle?
  end

  test "machines list only members with a bridge token" do
    with_bridge = add_member
    with_bridge.generate_bridge_token!
    add_member # no token

    machines = BoardPresence.for(team: @team, user: @user).machines
    assert_equal [ with_bridge.id ], machines.map { |m| m.owner.id }
  end

  test "online when seen within the window, stale otherwise" do
    fresh = add_member
    fresh.generate_bridge_token!
    fresh.update_columns(bridge_seen_at: 30.seconds.ago, bridge_client: "Apollo")

    old = add_member
    old.generate_bridge_token!
    old.update_columns(bridge_seen_at: (BoardPresence::ONLINE_WINDOW + 1.minute).ago)

    machines = BoardPresence.for(team: @team, user: @user).machines.index_by { |m| m.owner.id }
    assert machines[fresh.id].online?
    assert_equal "Apollo", machines[fresh.id].client
    refute machines[old.id].online?
  end

  test "boundary: a machine exactly at the window is stale" do
    member = add_member
    member.generate_bridge_token!
    member.update_columns(bridge_seen_at: BoardPresence::ONLINE_WINDOW.ago)

    machine = BoardPresence.for(team: @team, user: @user).machines.first
    refute machine.online?
  end

  test "machine surfaces the ref of a visible claimed task" do
    member = add_member
    member.generate_bridge_token!
    conversation = @user.conversations.create!(team: @team, project: @project, visibility: :team)
    run = @team.workflow_runs.create!(conversation: conversation, status: :awaiting_local)
    task = run.tasks.create!(position: 0, delegated: true, status: :running,
                             claimed_by_user: member, claimed_at: Time.current)

    machine = BoardPresence.for(team: @team, user: @user).machines.first
    assert_equal task.ref, machine.task_ref
  end

  test "machine does not leak a private run's claimed ref" do
    member = add_member
    member.generate_bridge_token!
    conversation = member.conversations.create!(team: @team, project: @project, visibility: :personal)
    run = @team.workflow_runs.create!(conversation: conversation, status: :awaiting_local)
    run.tasks.create!(position: 0, delegated: true, status: :running,
                      claimed_by_user: member, claimed_at: Time.current)

    machine = BoardPresence.for(team: @team, user: @user).machines.first
    assert_nil machine.task_ref
  end

  test "machine does not surface a claimed ref from another team the member shares" do
    member = add_member
    member.generate_bridge_token!

    # A separate team the member also belongs to but the viewer does not.
    other_team = Team.create!(name: "Other-#{SecureRandom.hex(3)}", personal: false)
    other_team.memberships.create!(user: member, role: :admin)
    other_project = other_team.projects.create!(name: "Other")
    conversation = member.conversations.create!(team: other_team, project: other_project, visibility: :team)
    run = other_team.workflow_runs.create!(conversation: conversation, status: :awaiting_local)
    run.tasks.create!(position: 0, delegated: true, status: :running,
                      claimed_by_user: member, claimed_at: Time.current)

    machine = BoardPresence.for(team: @team, user: @user).machines.find { |m| m.owner == member }
    assert_nil machine.task_ref, "a run in another team must not leak onto this team's board"
  end

  test "online_count tallies only machines within the window" do
    fresh = add_member
    fresh.generate_bridge_token!
    fresh.update_columns(bridge_seen_at: 20.seconds.ago)
    stale = add_member
    stale.generate_bridge_token!
    stale.update_columns(bridge_seen_at: (BoardPresence::ONLINE_WINDOW + 1.minute).ago)

    presence = BoardPresence.for(team: @team, user: @user)
    assert_equal 2, presence.machines.size
    assert_equal 1, presence.online_count
  end

  test "gates track the active project filter" do
    gated = add_member
    atlas = @team.projects.create!(name: "Atlas")
    conversation = gated.conversations.create!(team: @team, project: @project, visibility: :team)
    @team.workflow_runs.create!(conversation: conversation, status: :awaiting_approval)
         .tasks.create!(position: 0, gate: :approval, status: :awaiting_approval, name: "review")

    unfiltered = BoardPresence.for(team: @team, user: @user).people.find { |p| p.member == gated }
    assert_equal 1, unfiltered.gate_count

    filtered = BoardPresence.for(team: @team, user: @user, project_ids: [ atlas.id ])
                            .people.find { |p| p.member == gated }
    assert filtered.idle?, "a gate outside the filtered projects must not show"
  end

  test "claimed task ref tracks the active project filter" do
    member = add_member
    member.generate_bridge_token!
    atlas = @team.projects.create!(name: "Atlas")
    conversation = @user.conversations.create!(team: @team, project: @project, visibility: :team)
    run = @team.workflow_runs.create!(conversation: conversation, status: :awaiting_local)
    task = run.tasks.create!(position: 0, delegated: true, status: :running,
                             claimed_by_user: member, claimed_at: Time.current)

    shown = BoardPresence.for(team: @team, user: @user).machines.find { |m| m.owner == member }
    assert_equal task.ref, shown.task_ref

    hidden = BoardPresence.for(team: @team, user: @user, project_ids: [ atlas.id ])
                          .machines.find { |m| m.owner == member }
    assert_nil hidden.task_ref, "a claim outside the filtered projects must not show"
  end

  test "no bridge users yields no machines" do
    add_member
    assert_empty BoardPresence.for(team: @team, user: @user).machines
  end
end
