module Agent
  module Runtime
    # First-message timing shared by the sandbox transports (E2b, Daytona).
    # Each records @started_at in #start; this logs the ms to pi's first RPC
    # line once — the boot the user waits through before output streams. The
    # log tag is derived from the transport class (e2b / daytona).
    module TransportTiming
      def log_first_message
        return if @first_message_logged

        @first_message_logged = true
        ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started_at) * 1000).round
        tag = self.class.name.demodulize.delete_suffix("Transport").downcase
        Rails.logger.info("[#{tag} timing] first_pi_message=#{ms}ms")
      end
    end
  end
end
