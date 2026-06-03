require "securerandom"
require "digest"
require "base64"

module Mcp
  module Oauth
    # PKCE (RFC 7636) pair for an authorization-code flow. The verifier is
    # held server-side (in the OAuth `state` payload) across the redirect;
    # the S256 challenge goes on the authorize URL. Both are unpadded
    # base64url per spec.
    class Pkce
      attr_reader :verifier, :challenge

      def initialize(verifier: SecureRandom.urlsafe_base64(64))
        @verifier = verifier.tr("=", "")
        @challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(@verifier)).tr("=", "")
      end

      def challenge_method
        "S256"
      end
    end
  end
end
