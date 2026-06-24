require "test_helper"

class Webhooks::GithubEventProcessorTest < ActiveSupport::TestCase
  setup do
    @team = Team.create!(name: "Acme")
    @connector = @team.connectors.create!(name: "github", transport: :http,
                                          catalog_key: "github",
                                          definition: { "url" => "https://mcp.example/" },
                                          settings: { "bot_installation_id" => "42" })
  end

  def process(event:, delivery:, payload:)
    Webhooks::GithubEventProcessor.new(event: event, delivery: delivery, payload: payload).call
  end

  def payload(action: "opened", installation_id: 42)
    { "action" => action, "installation" => { "id" => installation_id }, "number" => 7 }
  end

  test "records an event for the connector's team" do
    assert_difference "WebhookEvent.count", 1 do
      process(event: "pull_request", delivery: "d-1", payload: payload)
    end
    event = WebhookEvent.last
    assert_equal @team, event.team
    assert_equal "pull_request.opened", event.event_type
    assert_equal "42", event.source_installation_id
    assert_equal 7, event.payload["number"]
  end

  test "bare event name when the payload has no action" do
    process(event: "push", delivery: "d-2", payload: { "installation" => { "id" => 42 } })
    assert_equal "push", WebhookEvent.last.event_type
  end

  test "drops events for an unknown installation" do
    assert_no_difference "WebhookEvent.count" do
      process(event: "pull_request", delivery: "d-3", payload: payload(installation_id: 999))
    end
  end

  test "drops events with no installation id" do
    assert_no_difference "WebhookEvent.count" do
      process(event: "pull_request", delivery: "d-4", payload: { "action" => "opened" })
    end
  end

  test "redelivery of the same delivery id is idempotent" do
    process(event: "pull_request", delivery: "d-5", payload: payload)
    assert_no_difference "WebhookEvent.count" do
      process(event: "pull_request", delivery: "d-5", payload: payload)
    end
  end
end
