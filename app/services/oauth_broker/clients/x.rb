module OauthBroker
  module Clients
    # The X side of the broker. Refresh delegates to XApp::Oauth — X
    # rotates the refresh token on every refresh and echoes the new one,
    # which OauthGrant#absorb! persists in the same save as the access
    # token. XApp errors are re-raised as broker errors so callers see
    # one failure vocabulary; InvalidGrantError passes through untouched.
    module X
      module_function

      def refresh(refresh_token)
        XApp::Oauth.refresh(refresh_token)
      rescue XApp::Oauth::Error => error
        raise OauthBroker::Error, error.message
      end

      def revoke(token)
        XApp::Oauth.revoke(token)
      rescue XApp::Oauth::Error => error
        raise OauthBroker::Error, error.message
      end
    end
  end
end
