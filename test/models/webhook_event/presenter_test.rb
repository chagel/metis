require "test_helper"

class WebhookEvent::PresenterTest < ActiveSupport::TestCase
  setup { @team = Team.create!(name: "Acme") }

  def present(event_type, payload)
    WebhookEvent.new(team: @team, provider: :github, event_type: event_type, payload: payload).present
  end

  test "push summarizes commit count and branch, links the compare url" do
    p = present("push", {
      "ref" => "refs/heads/main", "compare" => "https://github.com/o/r/compare/a...b",
      "commits" => [ {}, {} ], "sender" => { "login" => "octo", "avatar_url" => "https://av/octo.png" }
    })
    assert_equal "octo", p.actor
    assert_equal "https://av/octo.png", p.avatar_url
    assert_equal "pushed 2 commits to main", p.summary
    assert_equal "https://github.com/o/r/compare/a...b", p.url
  end

  test "push pluralizes a single commit" do
    p = present("push", { "ref" => "refs/heads/dev", "commits" => [ {} ] })
    assert_equal "pushed 1 commit to dev", p.summary
  end

  test "pull_request opened" do
    p = present("pull_request.opened", {
      "number" => 7, "pull_request" => { "title" => "Add X", "html_url" => "https://gh/pr/7" }
    })
    assert_equal "opened PR #7: Add X", p.summary
    assert_equal "https://gh/pr/7", p.url
  end

  test "a merged pull_request says merged, not closed" do
    p = present("pull_request.closed", {
      "number" => 7, "pull_request" => { "title" => "Add X", "html_url" => "u", "merged" => true }
    })
    assert_equal "merged PR #7: Add X", p.summary
  end

  test "synchronize reads as updated" do
    p = present("pull_request.synchronize", { "number" => 7, "pull_request" => { "title" => "Add X" } })
    assert_equal "updated PR #7: Add X", p.summary
  end

  test "issues opened" do
    p = present("issues.opened", {
      "issue" => { "number" => 3, "title" => "Bug", "html_url" => "https://gh/i/3" }
    })
    assert_equal "opened issue #3: Bug", p.summary
    assert_equal "https://gh/i/3", p.url
  end

  test "issue_comment links the comment, names the thread number" do
    p = present("issue_comment.created", {
      "issue" => { "number" => 3 }, "comment" => { "html_url" => "https://gh/i/3#c1" }
    })
    assert_equal "commented on #3", p.summary
    assert_equal "https://gh/i/3#c1", p.url
  end

  test "an unknown action falls back to a humanized verb" do
    p = present("pull_request.ready_for_review", { "number" => 7, "pull_request" => { "title" => "X" } })
    assert_equal "marked ready PR #7: X", p.summary
  end

  test "a submitted review reads by its state, not the action" do
    p = present("pull_request_review.submitted", {
      "review" => { "state" => "approved", "html_url" => "https://gh/pr/7#r1" },
      "pull_request" => { "number" => 7, "title" => "Ship it" }
    })
    assert_equal "approved PR #7: Ship it", p.summary
    assert_equal "https://gh/pr/7#r1", p.url
  end

  test "a changes-requested review" do
    p = present("pull_request_review.submitted", {
      "review" => { "state" => "changes_requested" },
      "pull_request" => { "number" => 7, "title" => "Ship it" }
    })
    assert_equal "requested changes on PR #7: Ship it", p.summary
  end

  test "a review comment reads like a comment, linking the comment" do
    p = present("pull_request_review_comment.created", {
      "pull_request" => { "number" => 7 }, "comment" => { "html_url" => "https://gh/pr/7#c9" }
    })
    assert_equal "commented on #7", p.summary
    assert_equal "https://gh/pr/7#c9", p.url
  end

  test "a published release names and links it" do
    p = present("release.published", {
      "release" => { "name" => "v1.2.0", "html_url" => "https://gh/rel/1" }
    })
    assert_equal "published release v1.2.0", p.summary
    assert_equal "https://gh/rel/1", p.url
  end

  test "a release with no name falls back to its tag" do
    p = present("release.published", { "release" => { "tag_name" => "v1.2.0" } })
    assert_equal "published release v1.2.0", p.summary
  end

  test "an unhandled event type degrades to a verb-first spelled-out name" do
    assert_equal "resolved pull request review thread",
                 present("pull_request_review_thread.resolved", {}).summary
    assert_equal "created milestone", present("milestone.created", {}).summary
    assert_nil present("milestone.created", {}).url
  end

  test "actor falls back when the payload has no sender" do
    assert_equal "someone", present("push", {}).actor
  end
end
