require "openssl"

# Inbound Linear webhooks. Unlike GitHub's one deployment-wide App endpoint,
# each team's webhook is its own: the `:token` in the path resolves the
# connector, and that connector's signing secret authes the delivery.
# Session-less and CSRF-free via ActionController::API — the HMAC is the
# only auth. See docs/connectors.md.
module Webhooks
  class LinearController < ActionController::API
    # Reject deliveries whose body timestamp is this far from now — Linear's
    # own replay-protection guidance.
    REPLAY_WINDOW_MS = 60_000

    def create
      # Read the token from the path, not params — touching params would
      # force Rails to parse the (possibly malformed) JSON body before we
      # can rescue it ourselves below.
      connector = Connector.for_linear_webhook(request.path_parameters[:token]).first
      return head :not_found unless connector

      body = request.raw_post
      return head :unauthorized unless valid_signature?(connector, body)

      payload = JSON.parse(body)
      return head :unauthorized unless fresh?(payload)

      LinearEventProcessor.new(
        connector: connector,
        delivery: request.headers["Linear-Delivery"],
        event: request.headers["Linear-Event"],
        payload: payload
      ).call

      head :ok
    rescue JSON::ParserError
      head :bad_request
    end

    private

    def valid_signature?(connector, body)
      secret = connector.linear_webhook_secret
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
