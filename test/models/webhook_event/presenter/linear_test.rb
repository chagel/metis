require "test_helper"

class WebhookEvent::Presenter::LinearTest < ActiveSupport::TestCase
  setup { @team = Team.create!(name: "Acme") }

  def present(event_type, payload)
    WebhookEvent.new(team: @team, provider: :linear, event_type: event_type, payload: payload).present
  end

  test "an issue create names the actor, identifier, title, and links the url" do
    p = present("Issue.create", {
      "actor" => { "name" => "Ada", "avatarUrl" => "https://av/ada.png" },
      "url" => "https://linear.app/acme/issue/ENG-1",
      "data" => { "identifier" => "ENG-1", "title" => "Fix login" }
    })
    assert_equal "Ada", p.actor
    assert_equal "https://av/ada.png", p.avatar_url
    assert_equal "created issue ENG-1: Fix login", p.summary
    assert_equal "https://linear.app/acme/issue/ENG-1", p.url
  end

  test "a project update reads with the project name" do
    p = present("Project.update", { "data" => { "name" => "Q3 Roadmap" } })
    assert_equal "updated project Q3 Roadmap", p.summary
  end

  test "a comment reads as commented on the issue" do
    p = present("Comment.create", { "data" => { "issue" => { "identifier" => "ENG-1" } } })
    assert_equal "commented on ENG-1", p.summary
  end

  test "an unhandled type degrades to a verb-first spelled-out name" do
    assert_equal "created cycle", present("Cycle.create", {}).summary
    assert_equal "updated issue label", present("IssueLabel.update", {}).summary
  end

  test "actor falls back when the payload has no actor" do
    assert_equal "someone", present("Issue.create", {}).actor
  end
end
