require "openssl"

# Single inbound endpoint for the deployment's Linear OAuth app. Linear
# posts every authorizing workspace's events here; the processor fans them
# out to the owning team by the payload's organizationId — the GitHub-App
# shape. Session-less and CSRF-free via ActionController::API; the HMAC is
# the only auth. See docs/connectors.md.
module Webhooks
  class LinearController < ActionController::API
    # Reject deliveries whose body timestamp is this far from now — Linear's
    # own replay-protection guidance.
    REPLAY_WINDOW_MS = 60_000

    def create
      body = request.raw_post
      return head :unauthorized unless valid_signature?(body)

      payload = JSON.parse(body)
      return head :unauthorized unless fresh?(payload)

      LinearEventProcessor.new(
        event: request.headers["Linear-Event"],
        delivery: request.headers["Linear-Delivery"],
        payload: payload
      ).call

      head :ok
    rescue JSON::ParserError
      head :bad_request
    end

    private

    def valid_signature?(body)
      secret = LinearApp::Config.webhook_secret
      return false if secret.blank?

      expected = OpenSSL::HMAC.hexdigest("SHA256", secret, body)
      given = request.headers["Linear-Signature"].to_s
      ActiveSupport::SecurityUtils.secure_compare(expected, given)
    end

    # webhookTimestamp is UNIX milliseconds in the body; bail on a stale
    # (replayed) or absent one.
    def fresh?(payload)
      ts = payload["webhookTimestamp"]
      return false if ts.blank?

      (Time.current.to_f * 1000 - ts.to_i).abs <= REPLAY_WINDOW_MS
    end
  end
end
