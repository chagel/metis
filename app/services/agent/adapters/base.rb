module Agent
  module Adapters
    # Interface every backend adapter implements. An adapter drives one
    # conversation's backend and yields Agent::UiEvent objects.
    class Base
      attr_reader :conversation

      def initialize(conversation:, **opts)
        @conversation = conversation
        @opts = opts
      end

      # Run +input+ against the backend, yielding Agent::UiEvent objects
      # until the turn finishes. Returns an Enumerator if no block given.
      #
      # +images+ and +files+ are the user message's attachments — objects
      # responding to #filename, #content_type, and #download. How a
      # backend delivers them (inline, staged into a workspace, ...) is
      # its own concern.
      def stream(input, images: [], files: [], &block)
        raise NotImplementedError, "#{self.class} must implement #stream"
      end

      # Abort the in-flight run, if any.
      def abort
        raise NotImplementedError, "#{self.class} must implement #abort"
      end

      # Backend-native session id, persisted on the Conversation so the
      # next turn can resume. nil if the backend has no resumable session.
      def native_session_id
        nil
      end

      # Cumulative token counts for the session after the last run —
      # a hash with "input"/"output"/"cacheRead" keys, or nil.
      def token_totals
        nil
      end

      # Context-window usage after the last run — a hash with
      # "tokens"/"contextWindow"/"percent" keys, or nil.
      def context_usage
        nil
      end

      # Cumulative session cost in USD after the last run, or nil if the
      # backend does not price runs.
      def cost_total
        nil
      end

      # The model the backend resolved for the last run — a hash with
      # "id"/"name"/"provider" keys, or nil.
      def model_info
        nil
      end

      # Where the last run physically executed — a hash with a "runtime"
      # name and per-runtime detail — or nil.
      def runtime_info
        nil
      end
    end
  end
end
