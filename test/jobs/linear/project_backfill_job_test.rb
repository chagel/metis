require "test_helper"

class Linear::ProjectBackfillJobTest < ActiveSupport::TestCase
  setup do
    @team = Team.create!(name: "Acme")
    @connector = @team.connectors.create!(name: "linear", transport: :http, catalog_key: "linear",
                                          definition: { "url" => "https://mcp.linear.app/mcp" })
    @connector.connector_credentials.create!.store_linear_api!({ "access_token" => "lin-tok" })
  end

  def event(data:, project: nil)
    WebhookEvent.create!(provider: :linear, external_id: SecureRandom.uuid, team: @team,
                         project: project, event_type: "Comment.create",
                         payload: { "data" => data })
  end

  def stub_issue_project(uuid, &block)
    fake = Object.new
    fake.define_singleton_method(:issue_project_id) { |_id| uuid }
    with_stub(Linear::Api, :new, ->(_token) { fake }, &block)
  end

  test "binds the project when the issue resolves to a bound linear project" do
    project = @team.projects.create!(name: "Metis", linear_project: "11111111-2222-3333-4444-555555555555")
    row = event(data: { "issueId" => "issue-9" })

    stub_issue_project(project.linear_project) do
      Linear::ProjectBackfillJob.perform_now(row.id)
    end

    assert_equal project, row.reload.project
  end

  test "reads the issue id from a nested issue node" do
    project = @team.projects.create!(name: "Metis", linear_project: "11111111-2222-3333-4444-555555555555")
    row = event(data: { "issue" => { "id" => "issue-9" } })

    stub_issue_project(project.linear_project) do
      Linear::ProjectBackfillJob.perform_now(row.id)
    end

    assert_equal project, row.reload.project
  end

  test "no-op when the issue's project binds no team project" do
    row = event(data: { "issueId" => "issue-9" })

    stub_issue_project("99999999-2222-3333-4444-555555555555") do
      Linear::ProjectBackfillJob.perform_now(row.id)
    end

    assert_nil row.reload.project
  end

  test "no-op when the event already has a project" do
    project = @team.projects.create!(name: "Metis", linear_project: "11111111-2222-3333-4444-555555555555")
    row = event(data: { "issueId" => "issue-9" }, project: project)

    with_stub(Linear::Api, :new, ->(_token) { raise "should not call the API" }) do
      Linear::ProjectBackfillJob.perform_now(row.id)
    end

    assert_equal project, row.reload.project
  end

  test "no-op when the team has no linear api token" do
    @connector.connector_credentials.destroy_all
    row = event(data: { "issueId" => "issue-9" })

    Linear::ProjectBackfillJob.perform_now(row.id)

    assert_nil row.reload.project
  end

  test "swallows api errors and leaves the project null" do
    @team.projects.create!(name: "Metis", linear_project: "11111111-2222-3333-4444-555555555555")
    row = event(data: { "issueId" => "issue-9" })

    fake = Object.new
    fake.define_singleton_method(:issue_project_id) { |_id| raise Linear::Api::Error, "boom" }
    with_stub(Linear::Api, :new, ->(_token) { fake }) do
      assert_nothing_raised { Linear::ProjectBackfillJob.perform_now(row.id) }
    end

    assert_nil row.reload.project
  end
end
