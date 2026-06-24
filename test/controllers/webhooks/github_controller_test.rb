require "test_helper"

class Webhooks::GithubControllerTest < ActionDispatch::IntegrationTest
  SECRET = "shhh-test-secret".freeze

  setup do
    @team = Team.create!(name: "Acme")
    @team.connectors.create!(name: "github", transport: :http, catalog_key: "github",
                             definition: { "url" => "https://mcp.example/" },
                             settings: { "bot_installation_id" => "42" })
  end

  def with_secret(&block)
    with_stub(GithubApp::Config, :webhook_secret, ->(*) { SECRET }, &block)
  end

  def sign(body)
    "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", SECRET, body)
  end

  def post_event(body, signature:, event: "pull_request", delivery: "d-1")
    post "/webhooks/github", params: body,
         headers: { "X-Hub-Signature-256" => signature, "X-GitHub-Event" => event,
                    "X-GitHub-Delivery" => delivery, "Content-Type" => "application/json" }
  end

  def body(installation_id: 42)
    { action: "opened", installation: { id: installation_id }, number: 7 }.to_json
  end

  test "valid signature records the event" do
    with_secret do
      assert_difference "WebhookEvent.count", 1 do
        post_event(body, signature: sign(body))
      end
    end
    assert_response :ok
  end

  test "invalid signature is rejected and records nothing" do
    with_secret do
      assert_no_difference "WebhookEvent.count" do
        post_event(body, signature: "sha256=deadbeef")
      end
    end
    assert_response :unauthorized
  end

  test "missing webhook secret refuses every delivery" do
    with_stub(GithubApp::Config, :webhook_secret, ->(*) { nil }) do
      post_event(body, signature: sign(body))
    end
    assert_response :unauthorized
  end

  test "unknown installation is accepted but stored nothing" do
    with_secret do
      payload = body(installation_id: 999)
      assert_no_difference "WebhookEvent.count" do
        post_event(payload, signature: sign(payload))
      end
    end
    assert_response :ok
  end

  test "malformed json is a bad request" do
    with_secret do
      post_event("not json", signature: sign("not json"))
    end
    assert_response :bad_request
  end
end
