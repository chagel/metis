module Agent
  # A Runtime is *where* a coding agent runs — the second axis of
  # composition alongside the agent itself (Agent::Adapters). It owns the
  # agent's filesystem (session + workspace directories), the lifecycle
  # bracket around a run (provision -> yield a live session -> finalize),
  # and, for remote runtimes, the transport that carries the agent's RPC.
  #
  # Contract (see Runtime::Base):
  #   #session_dir              -> path for the agent's --session-dir
  #   #run(pi_args:) { |sess| } -> provision, open a PiAgent::Session,
  #                                yield it, finalize (persist + tear down)
  #
  # Runtime::Local runs the agent as a local subprocess; Runtime::Docker
  # runs it in a Docker container; Runtime::E2b runs it inside a secure
  # E2B microVM; Runtime::Daytona inside a Daytona elastic sandbox.
  module Runtime
    # Human labels for the runtime picker, keyed by id. The picker only
    # shows enabled runtimes (Runtime.enabled); this is the display layer.
    LABELS = {
      local:   "Local",
      docker:  "Docker · isolated",
      e2b:     "E2B · microVM",
      daytona: "Daytona · sandbox"
    }.freeze

    # Resolve the runtime for a conversation. The runtime is a per-deployment
    # *default* (config.x.agent.runtime) that a conversation may override at
    # creation via settings["runtime"], gated to the deployment's allow-list
    # (Runtime.enabled). The choice is fixed for the conversation's life —
    # each runtime persists the working tree in its own store, so switching
    # mid-conversation would strand it (see docs/coding-runtime.md).
    def self.for(conversation)
      build(conversation, runtime_name_for(conversation))
    end

    # The runtime a conversation should run on: its own choice when that is
    # still on the menu, else the deployment default. A *locked*
    # conversation (one that has already provisioned state) keeps its stored
    # runtime even if the operator later drops it from the menu — its state
    # can't be relocated. A turn must never die on a stale settings value,
    # so an unresolvable choice falls back rather than raising.
    def self.runtime_name_for(conversation)
      chosen = conversation.settings["runtime"].presence&.to_sym
      return default unless chosen
      return chosen if conversation.runtime_locked? && known?(chosen)
      enabled.include?(chosen) ? chosen : default
    end

    # The deployment default runtime.
    def self.default
      Rails.application.config.x.agent.runtime
    end

    # Runtimes offered in the per-conversation picker. The configured
    # default is always included; `local` is filtered out in production
    # unless explicitly allowed (it is not an isolation boundary).
    def self.enabled
      list = (Rails.application.config.x.agent.enabled_runtimes | [ default ])
        .select { |name| known?(name) }
      unless Rails.application.config.x.agent.allow_local_runtime
        list -= [ :local ] if Rails.env.production? && default != :local
      end
      list
    end

    # Whether the picker should be shown at all (more than one choice).
    def self.selectable?
      enabled.size > 1
    end

    # [[label, id], …] for options_for_select, default first.
    def self.picker_options
      enabled.sort_by { |name| name == default ? 0 : 1 }
              .map { |name| [ LABELS.fetch(name, name.to_s.titleize), name.to_s ] }
    end

    def self.known?(name)
      LABELS.key?(name&.to_sym)
    end

    def self.build(conversation, name)
      runtime_class(name).new(conversation: conversation)
    end

    # The configured runtime class (no conversation needed).
    def self.runtime_class(name = Rails.application.config.x.agent.runtime)
      case name&.to_sym
      when :local   then Local
      when :docker  then Docker
      when :e2b     then E2b
      when :daytona then Daytona
      else
        raise Agent::Error, "Unknown agent runtime #{name.inspect} — set config.x.agent.runtime"
      end
    end

    # Open a bare `pi --mode rpc` session in the configured runtime for a
    # control-plane query (e.g. get_available_models), yield it, and tear
    # it down. Unlike #run this carries no conversation and stages no
    # workspace — it asks pi about itself, not about a turn. Each runtime
    # owns *how* its pi is reached, so the catalog stays runtime-correct
    # instead of assuming a local subprocess.
    def self.control_session(env: {}, &block)
      runtime_class.control_session(env: env, &block)
    end

    # The pi extensions shipped with the app, version-controlled under
    # .pi/extensions/ (one self-contained <name>/index.ts each). pi runs
    # in a scratch workspace, so they are not on its discovery path: each
    # runtime makes them reachable from pi's execution environment and the
    # Pi adapter loads them explicitly with `pi --extension`.
    def self.extension_sources
      Dir.glob(Rails.root.join(".pi/extensions/*/index.ts")).sort.map { |path| Pathname.new(path) }
    end
  end
end
