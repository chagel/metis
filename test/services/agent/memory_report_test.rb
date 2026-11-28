require "test_helper"

class Agent::MemoryReportTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "mr-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @team = @user.personal_team
    @conversation = @user.conversations.create!(team: @team)
    @memory = UserMemory.create!(user: @user, team: @team, content: "short answers", kind: :preference)
  end

  def reply(**attrs)
    @conversation.messages.create!({ role: :assistant, content: "ok", streaming_status: :done }.merge(attrs))
  end

  def report(since: 1.day.ago) = Agent::MemoryReport.new(@user, @team, since: since)

  test "counts each outcome of the replies a memory shaped" do
    reply(applied_memory_ids: [ @memory.id ])
    reply(applied_memory_ids: [ @memory.id ], corrected_at: Time.current, correction_note: "too terse")
    reply(applied_memory_ids: [ @memory.id ], streaming_status: :canceled)
    forked = reply(applied_memory_ids: [ @memory.id ])
    @user.conversations.create!(team: @team, forked_from_message: forked)

    entry = report.to_h[:memories].find { |m| m[:id] == @memory.id }
    assert_equal({ "applied" => 4, "corrected" => 1, "cancelled" => 1, "forked" => 1 }, entry[:outcomes])
  end

  test "lists corrections on replies that used no memory, with their notes" do
    reply(corrected_at: Time.current, correction_note: "wanted a table")

    assert_equal [ "wanted a table" ], report.to_h[:corrections_without_memory].map { |c| c[:note] }
  end

  test "totals compare corrections with the window before" do
    reply(corrected_at: 2.hours.ago)
    reply(corrected_at: 30.hours.ago)

    totals = report.to_h[:totals]
    assert_equal 1, totals[:corrections]
    assert_equal 1, totals[:corrections_previous_window]
  end

  test "reports the user's own deletions by kind, without text" do
    @team.memberships.find_by!(user: @user).record_memory_deletions!(%w[fact fact goal])

    assert_equal({ "fact" => 2, "goal" => 1 }, report.to_h[:deleted_by_you])
  end

  test "activity? is false when nothing happened since the window start" do
    @memory.update_columns(created_at: 2.days.ago, updated_at: 2.days.ago)
    assert_not report.activity?

    reply(applied_memory_ids: [ @memory.id ])
    assert report.activity?
  end

  test "reports gate decisions, hunch outcomes, 30 days of corrections and conversation titles" do
    run_conversation = @user.conversations.create!(team: @team, title: "Ship it")
    run_conversation.messages.create!(role: :user, kind: :review, sender: @user, streaming_status: :done,
                                      content: "M requested changes — use the staging bucket")
    Hunch.create!(user: @user, team: @team, title: "Draft the update", body: "b", why_now: "w", impact: :medium,
                  confidence: :medium, status: :dismissed, dismiss_reason: "already done", outcome_at: Time.current)
    Hunch.create!(user: @user, team: @team, title: "Old", body: "b", why_now: "w", impact: :medium,
                  confidence: :medium, status: :expired, outcome_at: Time.current)
    reply(corrected_at: 20.days.ago, correction_note: "no em dashes")
    @user.conversations.create!(team: @team, title: "Weekly investor update")

    data = report.to_h
    assert_equal [ "M requested changes — use the staging bucket" ], data[:gate_decisions].map { it[:decision] }
    assert_equal [ { title: "Draft the update", outcome: "dismissed", reason: "already done" } ], data[:hunches]
    assert_equal 1, data[:hunches_expired]
    assert_includes data[:correction_history].map { it[:note] }, "no em dashes"
    assert_includes data[:conversation_titles], "Weekly investor update"
    assert report.activity?
  end

  test "three new chats alone make a night worth reviewing" do
    @memory.update_columns(created_at: 2.days.ago, updated_at: 2.days.ago)
    @user.conversations.create!(team: @team, title: "Investor update")
    assert_not report.activity?, "two new chats aren't enough"

    @user.conversations.create!(team: @team, title: "Investor update again")
    assert report.activity?
  end

  test "tells the review whether this user may propose skills" do
    assert report.to_h[:can_propose_skills]

    team = Team.create!(name: "Work #{SecureRandom.hex(2)}")
    team.memberships.create!(user: @user, role: :member)
    assert_not Agent::MemoryReport.new(@user, team).to_h[:can_propose_skills]
  end

  test "chat titles span earlier nights, so a once-a-day task shows as recurring" do
    3.times { |day| @user.conversations.create!(team: @team, title: "Investor update", created_at: (day + 1).days.ago) }
    @user.conversations.create!(team: @team, title: "Ancient", created_at: 40.days.ago)

    titles = report(since: 12.hours.ago).to_h[:conversation_titles]
    assert_equal 3, titles.count("Investor update")
    assert_not_includes titles, "Ancient"
  end
end
