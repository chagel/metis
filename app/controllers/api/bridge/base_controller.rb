module Api
  module Bridge
    # Base for the bridge pull API: bearer-authed by the user's bridge
    # token, and every authenticated call doubles as a presence heartbeat.
    class BaseController < ActionController::API
      before_action :authenticate_bridge_user!

      private

      attr_reader :current_bridge_user

      def authenticate_bridge_user!
        @current_bridge_user = User.authenticate_bridge_token(bearer_token)
        return head :unauthorized unless @current_bridge_user

        @current_bridge_user.bridge_seen!(bridge_client_name)
      end

      def bearer_token
        request.headers["Authorization"].to_s[/\ABearer (.+)\z/, 1]
      end

      # Self-reported machine name, display only.
      def bridge_client_name
        request.headers["X-Bridge-Client"].to_s.strip.first(80).presence
      end
    end
  end
end
