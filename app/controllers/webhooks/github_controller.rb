require "openssl"

# Single inbound endpoint for the deployment's GitHub App. GitHub posts
# every event for every installation here; the processor fans them out to
# the owning team. Session-less and CSRF-free by virtue of
# ActionController::API — the HMAC signature is the only auth.
module Webhooks
  class GithubController < ActionController::API
    def create
      body = request.raw_post
      return head :unauthorized unless valid_signature?(body)

      GithubEventProcessor.new(
        event: request.headers["X-GitHub-Event"],
        delivery: request.headers["X-GitHub-Delivery"],
        payload: JSON.parse(body)
      ).call

      head :ok
    rescue JSON::ParserError
      head :bad_request
    end

    private

    def valid_signature?(body)
      secret = GithubApp::Config.webhook_secret
      return false if secret.blank?

      expected = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", secret, body)
      given = request.headers["X-Hub-Signature-256"].to_s
      ActiveSupport::SecurityUtils.secure_compare(expected, given)
    end
  end
end
