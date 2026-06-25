require "test_helper"

class Webhooks::LinearEventProcessorTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  ORG = "org-123".freeze

  setup do
    @team = Team.create!(name: "Acme")
    @team.connectors.create!(name: "linear", transport: :http, catalog_key: "linear",
                             definition: { "url" => "https://mcp.linear.app/mcp" },
                             settings: { "linear_organization_id" => ORG })
  end

  def process(event:, delivery:, payload:)
    Webhooks::LinearEventProcessor.new(event: event, delivery: delivery, payload: payload).call
  end

  def payload(action: "create", type: "Issue", org: ORG, data: { "id" => "issue-1" })
    { "action" => action, "type" => type, "organizationId" => org, "data" => data }
  end

  test "records an event for the organization's team" do
    assert_difference "WebhookEvent.count", 1 do
      process(event: "Issue", delivery: "d-1", payload: payload)
    end
    event = WebhookEvent.last
    assert_equal @team, event.team
    assert_equal "Issue.create", event.event_type
    assert_equal ORG, event.source_installation_id
  end

  test "bare event name when the payload has no action" do
    process(event: "Issue", delivery: "d-2", payload: { "type" => "Issue", "organizationId" => ORG })
    assert_equal "Issue", WebhookEvent.last.event_type
  end

  test "drops events for an unknown organization" do
    assert_no_difference "WebhookEvent.count" do
      process(event: "Issue", delivery: "d-3", payload: payload(org: "org-999"))
    end
  end

  test "drops events with no organization id" do
    assert_no_difference "WebhookEvent.count" do
      process(event: "Issue", delivery: "d-4", payload: { "action" => "create", "type" => "Issue" })
    end
  end

  test "redelivery of the same delivery id is idempotent" do
    process(event: "Issue", delivery: "d-5", payload: payload)
    assert_no_difference "WebhookEvent.count" do
      process(event: "Issue", delivery: "d-5", payload: payload)
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

  test "enqueues a project backfill for a projectless delivery that references an issue" do
    assert_enqueued_with(job: Linear::ProjectBackfillJob) do
      process(event: "Comment", delivery: "b-1",
              payload: payload(type: "Comment", data: { "id" => "c-1", "issueId" => "issue-9" }))
    end
  end

  test "does not enqueue a backfill when the delivery already resolved a project" do
    project = @team.projects.create!(name: "Metis", linear_project: "11111111-2222-3333-4444-555555555555")
    assert_no_enqueued_jobs only: Linear::ProjectBackfillJob do
      process(event: "Issue", delivery: "b-2",
              payload: payload(data: { "id" => "issue-1", "projectId" => project.linear_project, "issueId" => "issue-9" }))
    end
  end

  test "does not enqueue a backfill when there is no issue reference" do
    assert_no_enqueued_jobs only: Linear::ProjectBackfillJob do
      process(event: "Issue", delivery: "b-3", payload: payload(data: { "id" => "issue-1" }))
    end
  end
end
