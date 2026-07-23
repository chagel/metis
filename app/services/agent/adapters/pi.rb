module Agent
  module Adapters
    # The pi agent (one axis of composition). Drives a PiAgent::Session
    # obtained from a Runtime and translates pi's native event stream
    # into Agent::UiEvent objects.
    #
    # The adapter knows pi — its RPC protocol, event vocabulary, and CLI
    # arguments. It knows nothing about where pi runs; that is the
    # Runtime's job. v1 binds to Runtime::Local by default.
    #
    # Continuity: when the conversation already has a pi session
    # (backend_session_id present), --continue is passed so pi reloads
    # its history. pi's session id is captured after the run for
    # Conversation#backend_session_id.
    #
    # Credentials: --provider/--model/--api-key resolve through a
    # fallback chain — per-conversation settings override the deployment
    # defaults in config.x.agent. All unset -> pi falls back to its own
    # configuration.
    #
    # Project trust: Metis stages .pi/skills/ and AGENTS.md into pi's
    # workspace each turn. pi ≥ 0.79.0 gates project-local inputs behind
    # a trust decision; --approve tells pi to load them in non-interactive
    # RPC mode (the only mode Metis uses). Without it, pi would ignore
    # staged skills and context files when defaultProjectTrust is "ask"
    # (the default). See https://pi.dev/docs/latest/usage#project-trust.
    #
    # Attachments: images are sent inline via pi's vision protocol
    # (prompt images:); other files are projected into pi's
    # workspace/uploads/ by the runtime, and a note in the prompt tells
    # pi this turn's uploads are there.
    class Pi < Base
      def initialize(conversation:, runtime: nil, **opts)
        super(conversation: conversation, **opts)
        @runtime = runtime || Agent::Runtime.for(conversation)
        @session = nil
        @session_stats = nil
        @model_info = nil
        @last_text_message_id = nil
        @agent_ends = 0
      end

      def stream(input, images: [], files: [], &block)
        return enum_for(:stream, input, images: images, files: files) unless block

        @last_text_message_id = nil
        @agent_responded = false
        @agent_ends = 0
        @runtime.status_sink = lambda do |phase, message|
          block.call(Agent::UiEvent.new(:runtime_status, data: { phase: phase, message: message }.compact))
        end
        @runtime.run(pi_args: pi_args, extension_ui: Agent::HostBridge.handler(conversation)) do |session|
          @session = session
          session.prompt(prompt_with_files(input, files), images: pi_images(images)) do |pi_event|
            @agent_responded = true
            ui_event = translate(pi_event)
            block.call(ui_event) if ui_event
          end
          @session_stats = capture_stats(session)
          @model_info = capture_model(session)
        end
      rescue PiAgent::TimeoutError => e
        raise boot_timeout?(e) ? BootTimeout.new(e.message) : e
      ensure
        @session = nil
      end

      # Captured after the last run (see #stream). session_stats carries
      # token/context numbers; model identity comes from get_state.
      def native_session_id = @session_stats&.dig("sessionId")
      def token_totals = @session_stats&.dig("tokens")
      def context_usage = @session_stats&.dig("contextUsage")
      # Cumulative session cost in USD (pi prices each turn natively). nil
      # when a provider returns no usage and pi omits cost (e.g. Ollama).
      def cost_total = @session_stats&.dig("cost")
      def model_info = @model_info
      def runtime_info = @runtime.runtime_info
      def artifacts = @runtime.artifacts

      def abort
        @session&.abort
      end

      # Translate a PiAgent::Event into an Agent::UiEvent, or nil to drop
      # events the chat UI does not render (agent_start, non-final agent_end,
      # turn_start/end, compaction, queue updates, ...).
      def translate(event)
        case event.type
        when :message_start
          ui(:message_started, event, id: message_id(event), role: message_role(event))
        when :message_update
          translate_update(event)
        when :message_end
          # pi emits message_end for every message in the agent loop — the user
          # prompt and tool-result messages too. Only the assistant's carries
          # reply text; the others must not leak into the message body.
          message_role(event) == "assistant" ? ui(:message_finished, event, id: message_id(event), content: message_content(event)) : nil
        when :tool_execution_start
          note_skill_touched(event)
          ui(:tool_call_started, event,
             tool_call_id: event["toolCallId"], name: event["toolName"], args: event["args"],
             skill_slug: display_skill_slug(event["args"]))
        when :tool_execution_update
          ui(:tool_call_progress, event,
             tool_call_id: event["toolCallId"], output: content_text(event["partialResult"]))
        when :tool_execution_end
          ui(:tool_call_finished, event,
             tool_call_id: event["toolCallId"],
             output: content_text(event["result"]),
             is_error: event["isError"] ? true : false)
        when :agent_end
          # Not terminal: pi may retry, compact-and-retry, or run a queued
          # continuation after agent_end. The turn ends at agent_settled.
          @agent_ends += 1
          nil
        when :agent_settled
          Rails.logger.info("pi settled after #{@agent_ends} agent_end events (conversation #{conversation.id})") if @agent_ends > 1
          ui(:turn_finished, event)
        when :extension_error
          ui(:error, event, message: event.error_message)
        else
          event.error? ? ui(:error, event, message: event.error_message) : nil
        end
      end

      # pi CLI arguments for this conversation's run.
      def pi_args
        [ "--mode", "rpc", "--session-dir", @runtime.session_dir.to_s,
          "--approve",   # trust project-local inputs in non-interactive mode (pi ≥ 0.79.0)
          *resume_args, *credential_args, *extension_args ]
      end

      private

      # pi-agent-rb raises one TimeoutError for both the RPC ack wait ("Future
      # timed out…") and the event-stream wait; only a pre-event ack timeout is a dead boot.
      def boot_timeout?(error)
        !@agent_responded && error.message.start_with?("Future timed out")
      end

      WRITE_TOOL_NAMES = %w[write edit].freeze
      SKILL_PATH_REGEX = %r{\.pi/skills/([a-z0-9][a-z0-9\-]*)/}.freeze

      # Tell the runtime which skill slug this tool touched, so post-turn ingest
      # scans exactly those dirs. See docs/skills.md.
      def note_skill_touched(event)
        args = event["args"] || {}
        case event["toolName"]
        when *WRITE_TOOL_NAMES
          slug = skill_slug_from(args["path"])
          @runtime.note_skill_touched(slug) if slug
        when "bash"
          args["command"].to_s.scan(SKILL_PATH_REGEX).each { |m| @runtime.note_skill_touched(m.first) }
        end
      end

      def skill_slug_from(path)
        m = path.to_s.match(SKILL_PATH_REGEX)
        m && m[1]
      end

      # First skill slug found in any string arg — stamped on tool_call_started
      # so the activity log can label the call without re-parsing in the view.
      def display_skill_slug(args)
        return nil unless args.is_a?(Hash)

        match = args.values.find { |v| v.is_a?(String) && v.match?(SKILL_PATH_REGEX) }
        match && match[SKILL_PATH_REGEX, 1]
      end

      # Image attachments become pi's inline image content.
      def pi_images(images)
        images.map { |image| PiAgent::Image.from_bytes(image.download, mime_type: image.content_type) }
      end

      # The runtime projects uploaded files into ./uploads/; name this
      # turn's uploads in the prompt so pi knows to open them there.
      def prompt_with_files(input, files)
        names = files.map { |file| file.filename.to_s }
        return input if names.empty?

        note = "[Attached files, available in ./uploads/: #{names.join(', ')}]"
        input.present? ? "#{input}\n\n#{note}" : note
      end

      def resume_args
        conversation.backend_session_id.present? ? [ "--continue" ] : []
      end

      # Per-conversation settings override the deployment-level defaults
      # in config.x.agent. The api key is the deployment key matched to
      # the provider. All unset -> no flags, and pi falls back to its own
      # configuration.
      def credential_args
        model = conversation.configured_model
        provider = conversation.configured_provider

        args = []
        args += [ "--model", model ] if model.present?
        if provider.present?
          args += [ "--provider", provider ]
          key = Rails.application.config.x.agent.api_keys.to_h[provider]
          args += [ "--api-key", key ] if key.present?
        end
        args
      end

      # Load the app's bundled pi extensions (web tools, …). The runtime
      # resolves paths reachable from pi's execution environment.
      def extension_args
        @runtime.extension_paths.flat_map { |path| [ "--extension", path.to_s ] }
      end

      # pi's token usage, cost, and context-window stats for the run.
      # Never raised — stats are reporting, not the turn itself.
      def capture_stats(session)
        session.session_stats
      rescue StandardError
        nil
      end

      # The model pi resolved for the run, slimmed to id/name/provider.
      # Reporting only, so failures never raise.
      def capture_model(session)
        session.get_state.dig("data", "model")&.slice("id", "name", "provider")
      rescue StandardError
        nil
      end

      def translate_update(event)
        case event.raw.dig("assistantMessageEvent", "type")
        when "text_delta"     then ui(:text_delta, event, id: message_id(event), delta: segmented_delta(event))
        when "thinking_delta" then ui(:reasoning_delta, event, id: message_id(event), delta: event.delta)
        when "error"          then ui(:error, event, message: event.error_message)
        end
      end

      # pi splits a turn's assistant text across several messages — one per
      # run of text between tool calls — and the first delta of each new
      # message carries no leading whitespace. Concatenated naively that
      # fuses the segments ("project.The"); insert a paragraph break
      # whenever the text stream crosses into a new pi message.
      def segmented_delta(event)
        delta = event.delta.to_s
        return delta if delta.empty?

        id = message_id(event)
        delta = "\n\n#{delta}" if @last_text_message_id && id && id != @last_text_message_id
        @last_text_message_id = id if id
        delta
      end

      def ui(type, pi_event, **data)
        Agent::UiEvent.new(type, data: data.compact, native_ref: pi_event.raw)
      end

      def message_id(event)
        event.raw.dig("message", "id")
      end

      def message_role(event)
        event.raw.dig("message", "role")
      end

      def message_content(event)
        message = event.raw["message"]
        message && text_of(message["content"])
      end

      # A pi tool result / partialResult is { content: [blocks], details: }.
      def content_text(payload)
        payload && text_of(payload["content"])
      end

      def text_of(content)
        case content
        when String
          content
        when Array
          content.filter_map { |block| block["text"] if block.is_a?(Hash) && block["type"] == "text" }.join
        end
      end
    end
  end
end
