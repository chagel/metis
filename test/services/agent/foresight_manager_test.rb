require "test_helper"

module Agent
  class ForesightManagerTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "fm-#{SecureRandom.hex(4)}@example.com", password: "password123")
      @team = @user.personal_team
      @conversation = @user.conversations.create!(team: @team)
    end

    def call(op, params = {}) = Agent::ForesightManager.public_send(op, @conversation, params)

    def hunch_params(**overrides)
      { "title" => "Draft reply", "body" => "Hi Acme,", "why_now" => "Renewal is Friday",
        "evidence" => [ { "title" => "Thread", "url" => "https://mail.example/1" } ],
        "impact" => "high", "confidence" => "medium" }.merge(overrides.stringify_keys)
    end

    test "adding a direction creates the user's foresight routine" do
      result = call(:add, "title" => "Proactive agents", "brief" => "What's new")

      assert result[:ok]
      assert_equal "Proactive agents", Direction.find(result[:id]).title
      assert Foresight.routine_for(@user, @team).foresight?
    end

    test "update rewrites the view and open questions and stamps the exploration" do
      direction = Direction.create!(user: @user, team: @team, title: "Payments")
      assert call(:update, "id" => direction.id, "view" => "Stable", "open_questions" => [ "Q1", "" ])[:ok]

      direction.reload
      assert_equal "Stable", direction.view
      assert_equal [ "Q1" ], direction.open_questions
      assert direction.last_explored_at
    end

    test "update can't reach another user's direction" do
      other = User.create!(email: "fm-o-#{SecureRandom.hex(4)}@example.com", password: "password123")
      direction = Direction.create!(user: other, team: other.personal_team, title: "Theirs")
      assert_not call(:update, "id" => direction.id, "view" => "x")[:ok]
    end

    test "record saves a hunch tied to this run" do
      result = call(:record, hunch_params)

      hunch = Hunch.find(result[:id])
      assert hunch.ready?
      assert hunch.impact_high?
      assert_equal @conversation, hunch.conversation
      assert_equal "https://mail.example/1", hunch.evidence.first["url"]
    end

    test "record needs evidence and at least medium impact" do
      assert_match "evidence", call(:record, hunch_params(evidence: [ { "url" => "javascript:alert(1)" } ]))[:error]
      assert_match "impact", call(:record, hunch_params(impact: "low"))[:error]
    end

    test "record stops at the per-run cap" do
      Hunch::MAX_PER_RUN.times { assert call(:record, hunch_params)[:ok] }
      assert_match "already recorded", call(:record, hunch_params)[:error]
    end

    test "list returns the user's directions" do
      Direction.create!(user: @user, team: @team, title: "Payments")
      assert_equal [ "Payments" ], call(:list)[:directions].map { |d| d["title"] }
    end
  end
end
