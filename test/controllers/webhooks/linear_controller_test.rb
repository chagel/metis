require "test_helper"

class Webhooks::LinearControllerTest < ActionDispatch::IntegrationTest
  SECRET = "lin_wh_test_secret".freeze
  TOKEN = "tok-abc123".freeze

  setup do
    @team = Team.create!(name: "Acme")
    @connector = @team.connectors.create!(name: "linear", transport: :http, catalog_key: "linear",
                                          definition: { "url" => "https://mcp.linear.app/mcp" },
                                          settings: { "linear_webhook_token" => TOKEN })
    @connector.store_linear_webhook_secret!(SECRET)
  end

  def sign(body)
    OpenSSL::HMAC.hexdigest("SHA256", SECRET, body)
  end

  def body(timestamp: (Time.current.to_f * 1000).to_i)
    { action: "create", type: "Issue", organizationId: "org-1",
      data: { id: "issue-1" }, webhookTimestamp: timestamp }.to_json
  end

  def post_event(payload, token: TOKEN, signature: nil, event: "Issue", delivery: "d-1")
    post "/webhooks/linear/#{token}", params: payload,
         headers: { "Linear-Signature" => signature || sign(payload), "Linear-Event" => event,
                    "Linear-Delivery" => delivery, "Content-Type" => "application/json" }
  end

  test "valid signature records the event" do
    assert_difference "WebhookEvent.count", 1 do
      post_event(body)
    end
    assert_response :ok
    assert_equal @team, WebhookEvent.last.team
  end

  test "invalid signature is rejected and records nothing" do
    assert_no_difference "WebhookEvent.count" do
      post_event(body, signature: "deadbeef")
    end
    assert_response :unauthorized
  end

  test "an unknown token is not found and records nothing" do
    assert_no_difference "WebhookEvent.count" do
      post_event(body, token: "nope")
    end
    assert_response :not_found
  end

  test "a connector with no signing secret refuses the delivery" do
    @connector.connector_credentials.find_by(user: nil).destroy
    assert_no_difference "WebhookEvent.count" do
      post_event(body)
    end
    assert_response :unauthorized
  end

  test "a stale timestamp is rejected as a replay" do
    stale = body(timestamp: (Time.current.to_f * 1000).to_i - 120_000)
    assert_no_difference "WebhookEvent.count" do
      post_event(stale)
    end
    assert_response :unauthorized
  end

  test "malformed json is a bad request" do
    post_event("not json")
    assert_response :bad_request
  end
end
