require "test_helper"

class WebhookEventTest < ActiveSupport::TestCase
  def team
    @team ||= Team.create!(name: "Acme")
  end

  test "a valid github event saves" do
    event = WebhookEvent.new(team: team, provider: :github,
                             event_type: "pull_request.opened", payload: { "a" => 1 })
    assert event.save
    assert event.github?
  end

  test "event_type is required" do
    assert_not WebhookEvent.new(team: team, provider: :github).valid?
  end

  test "team is required" do
    assert_not WebhookEvent.new(provider: :github, event_type: "push").valid?
  end

  test "project is optional" do
    assert WebhookEvent.new(team: team, provider: :github, event_type: "push").valid?
  end

  test "provider+external_id is unique" do
    WebhookEvent.create!(team: team, provider: :github, event_type: "push", external_id: "d-1")
    dup = WebhookEvent.new(team: team, provider: :github, event_type: "push", external_id: "d-1")
    assert_raises(ActiveRecord::RecordNotUnique) { dup.save(validate: false) }
  end

  test "null external_id does not collide" do
    WebhookEvent.create!(team: team, provider: :github, event_type: "push")
    assert WebhookEvent.new(team: team, provider: :github, event_type: "push").save
  end
end
