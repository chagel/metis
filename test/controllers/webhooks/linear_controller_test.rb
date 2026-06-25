require "test_helper"

class Webhooks::LinearControllerTest < ActionDispatch::IntegrationTest
  SECRET = "lin_wh_test_secret".freeze
  ORG = "org-123".freeze

  setup do
    @team = Team.create!(name: "Acme")
    @team.connectors.create!(name: "linear", transport: :http, catalog_key: "linear",
                             definition: { "url" => "https://mcp.linear.app/mcp" },
                             settings: { "linear_organization_id" => ORG })
  end

  def with_secret(&block)
    with_stub(LinearApp::Config, :webhook_secret, ->(*) { SECRET }, &block)
  end

  def sign(body) = OpenSSL::HMAC.hexdigest("SHA256", SECRET, body)

  def body(org: ORG, timestamp: (Time.current.to_f * 1000).to_i)
    { action: "create", type: "Issue", organizationId: org,
      data: { id: "issue-1" }, webhookTimestamp: timestamp }.to_json
  end

  def post_event(payload, signature: nil, event: "Issue", delivery: "d-1")
    post "/webhooks/linear", params: payload,
         headers: { "Linear-Signature" => signature || sign(payload), "Linear-Event" => event,
                    "Linear-Delivery" => delivery, "Content-Type" => "application/json" }
  end

  test "valid signature records the event for the organization's team" do
    with_secret do
      assert_difference "WebhookEvent.count", 1 do
        post_event(body)
      end
    end
    assert_response :ok
    assert_equal @team, WebhookEvent.last.team
  end

  test "invalid signature is rejected and records nothing" do
    with_secret do
      assert_no_difference "WebhookEvent.count" do
        post_event(body, signature: "deadbeef")
      end
    end
    assert_response :unauthorized
  end

  test "missing webhook secret refuses every delivery" do
    with_stub(LinearApp::Config, :webhook_secret, ->(*) { nil }) do
      post_event(body)
    end
    assert_response :unauthorized
  end

  test "an unknown organization is accepted but stored nothing" do
    with_secret do
      payload = body(org: "org-999")
      assert_no_difference "WebhookEvent.count" do
        post_event(payload, signature: sign(payload))
      end
    end
    assert_response :ok
  end

  test "a stale timestamp is rejected as a replay" do
    with_secret do
      stale = body(timestamp: (Time.current.to_f * 1000).to_i - 120_000)
      assert_no_difference "WebhookEvent.count" do
        post_event(stale, signature: sign(stale))
      end
    end
    assert_response :unauthorized
  end

  test "malformed json is a bad request" do
    with_secret do
      post_event("not json", signature: sign("not json"))
    end
    assert_response :bad_request
  end
end
