require "test_helper"

class Webhooks::LinearEventProcessorTest < ActiveSupport::TestCase
  setup do
    @team = Team.create!(name: "Acme")
    @connector = @team.connectors.create!(name: "linear", transport: :http, catalog_key: "linear",
                                          definition: { "url" => "https://mcp.linear.app/mcp" },
                                          settings: { "linear_webhook_token" => "tok-1" })
  end

  def process(event:, delivery:, payload:)
    Webhooks::LinearEventProcessor.new(connector: @connector, event: event,
                                       delivery: delivery, payload: payload).call
  end

  def payload(action: "create", type: "Issue", data: { "id" => "issue-1" })
    { "action" => action, "type" => type, "organizationId" => "org-1", "data" => data }
  end

  test "records an event for the connector's team" do
    assert_difference "WebhookEvent.count", 1 do
      process(event: "Issue", delivery: "d-1", payload: payload)
    end
    event = WebhookEvent.last
    assert_equal @team, event.team
    assert_equal "Issue.create", event.event_type
    assert_equal "org-1", event.source_installation_id
    assert_equal "issue-1", event.payload.dig("data", "id")
  end

  test "bare event name when the payload has no action" do
    process(event: "Issue", delivery: "d-2", payload: { "type" => "Issue" })
    assert_equal "Issue", WebhookEvent.last.event_type
  end

  test "redelivery of the same delivery id is idempotent" do
    process(event: "Issue", delivery: "d-3", payload: payload)
    assert_no_difference "WebhookEvent.count" do
      process(event: "Issue", delivery: "d-3", payload: payload)
    end
  end

  test "resolves project for an issue via data.projectId" do
    project = @team.projects.create!(name: "Metis", linear_project: "11111111-2222-3333-4444-555555555555")
    process(event: "Issue", delivery: "p-1",
            payload: payload(data: { "id" => "issue-1", "projectId" => project.linear_project }))
    assert_equal project, WebhookEvent.last.project
  end

  test "resolves project for a Project event via data.id" do
    project = @team.projects.create!(name: "Metis", linear_project: "11111111-2222-3333-4444-555555555555")
    process(event: "Project", delivery: "p-2",
            payload: payload(type: "Project", data: { "id" => project.linear_project }))
    assert_equal project, WebhookEvent.last.project
  end

  test "leaves project null when no project binds the linear project" do
    @team.projects.create!(name: "Metis", linear_project: "99999999-2222-3333-4444-555555555555")
    process(event: "Issue", delivery: "p-3",
            payload: payload(data: { "id" => "issue-1", "projectId" => "11111111-2222-3333-4444-555555555555" }))
    assert_nil WebhookEvent.last.project
  end

  test "a bound project in another team does not resolve" do
    other = Team.create!(name: "Other")
    other.projects.create!(name: "Metis", linear_project: "11111111-2222-3333-4444-555555555555")
    process(event: "Issue", delivery: "p-4",
            payload: payload(data: { "id" => "issue-1", "projectId" => "11111111-2222-3333-4444-555555555555" }))
    assert_nil WebhookEvent.last.project
  end
end
