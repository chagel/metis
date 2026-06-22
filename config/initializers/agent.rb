# Agent runtime configuration.
#
# The runtime — *where* the coding agent runs — is a per-deployment
# choice. See
# Agent::Runtime.
#
#   :local  — pi as a local subprocess. NOT isolated; single-operator /
#             development only.
#   :docker — pi in a Docker container. Namespace-isolated; self-hosted,
#             needs a Docker daemon and an image (see docker:image).
#   :e2b    — pi inside a secure E2B microVM. The isolated runtime;
#             requires E2B_API_KEY and a template with pi baked in.
#   :daytona— pi inside a Daytona elastic sandbox. The Daytona-backed
#             isolated runtime; requires DAYTONA_API_KEY and a snapshot
#             with pi baked in (see the daytona:snapshot rake task).
Rails.application.config.x.agent.runtime =
  ENV.fetch("METIS_AGENT_RUNTIME", "local").to_sym

# E2B template (image) used by the :e2b runtime — should have pi
# installed. See the e2b:template rake task for the build definition.
Rails.application.config.x.agent.e2b_template =
  ENV.fetch("METIS_E2B_TEMPLATE", "base")

# Idle window after which a paused E2B sandbox is evicted (killed) by
# EvictPausedSandboxesJob. E2B keeps paused sandboxes indefinitely
# unless we tell it otherwise (docs/coding-runtime.md), so this knob
# bounds how long a long-idle conversation's working tree survives —
# the next turn provisions a fresh sandbox.
Rails.application.config.x.agent.e2b_eviction_window =
  ENV.fetch("METIS_E2B_EVICTION_HOURS", "24").to_i.hours

# Docker image used by the :docker runtime — pi baked in. Build it with
# the docker:image rake task.
Rails.application.config.x.agent.docker_image =
  ENV.fetch("METIS_DOCKER_IMAGE", "metis-pi")

# OCI runtime for the :docker runtime's containers. Unset uses the daemon
# default (runc) — namespace isolation over a shared host kernel. Set to
# "runsc" (gVisor) for a user-space kernel that intercepts syscalls,
# closing the kernel-escape gap that separates a plain container from a
# microVM — the isolation tier Metis wants for untrusted multi-tenant
# turns, at near-native local cost. Requires the runtime installed and
# registered on the host daemon. See docs/coding-runtime.md.
Rails.application.config.x.agent.docker_runtime =
  ENV["METIS_DOCKER_RUNTIME"].presence

# Daytona credentials and target for the :daytona runtime. The API key is a
# shared, deployment-level resource (no per-user keys). api_url/target are
# optional — unset uses the SDK defaults (https://app.daytona.io/api, the
# org's default region).
Rails.application.config.x.agent.daytona_api_key = ENV["DAYTONA_API_KEY"].presence
Rails.application.config.x.agent.daytona_api_url = ENV["DAYTONA_API_URL"].presence
Rails.application.config.x.agent.daytona_target  = ENV["DAYTONA_TARGET"].presence

# Daytona snapshot (image) used by the :daytona runtime — should have pi
# installed. See the daytona:snapshot rake task for the build definition.
Rails.application.config.x.agent.daytona_snapshot =
  ENV.fetch("METIS_DAYTONA_SNAPSHOT", "metis-pi")

# Idle-lifecycle intervals (minutes) passed to Daytona at sandbox create.
# Unlike E2B, where a suspended sandbox is free, Daytona keeps billing a
# STOPPED sandbox for disk storage; ARCHIVED moves the filesystem to cheap
# object storage (lower cost, slower to resume). So these intervals are cost
# control, not just cleanup — and they replace E2B's EvictPausedSandboxesJob
# (no Daytona eviction cron). A deleted sandbox's next turn provisions fresh
# (working tree gone, history intact). 0 disables an interval.
#
#   auto_stop    — a *crash* safety net only. Runtime::Daytona already stops
#                  the sandbox at end of turn (that is what ends compute
#                  billing); autoStop just catches one left RUNNING by a killed
#                  worker. It auto-stops on SDK inactivity, and a long
#                  autonomous turn produces none (log streaming rides the
#                  preview proxy, which Daytona excludes), so this MUST exceed
#                  the longest turn — keep it ≥ METIS_STALLED_TURN_MINUTES or a
#                  live turn gets stopped mid-flight.
#   auto_archive — how long a stopped (idle) sandbox waits before its
#                  filesystem moves to cheap storage. Lower = less disk cost,
#                  but a returning conversation pays a slower cold resume.
#   auto_delete  — how long before an idle sandbox is reaped entirely.
Rails.application.config.x.agent.daytona_auto_stop_minutes =
  ENV.fetch("METIS_DAYTONA_AUTO_STOP_MINUTES", "120").to_i
Rails.application.config.x.agent.daytona_auto_archive_minutes =
  ENV.fetch("METIS_DAYTONA_AUTO_ARCHIVE_MINUTES", "60").to_i
Rails.application.config.x.agent.daytona_auto_delete_minutes =
  ENV.fetch("METIS_DAYTONA_AUTO_DELETE_MINUTES", "1440").to_i

# Keep-warm window (seconds). After a turn, Runtime::Daytona schedules the
# sandbox stop this many seconds out (DaytonaStopJob) instead of stopping
# inline — so the stop never holds the worker, and a follow-up within the
# window reuses the still-running box (no stop, no resume). The trade-off is
# idle compute billing for the window; autoStop (above) is the backstop if the
# job never runs. 0 = stop as soon as the job runs (async, no warm window).
Rails.application.config.x.agent.daytona_keep_warm_seconds =
  ENV.fetch("METIS_DAYTONA_KEEP_WARM_SECONDS", "120").to_i

# pi's default provider/model — used when a conversation sets none of
# its own (the new-chat composer normally does). See
# Agent::Adapters::Pi#credential_args.
Rails.application.config.x.agent.provider = ENV["METIS_AGENT_PROVIDER"].presence
Rails.application.config.x.agent.model = ENV["METIS_AGENT_MODEL"].presence

# How long an assistant turn may sit pending/streaming before
# ReapStalledTurnsJob treats it as abandoned — its agent process died
# mid-turn (a worker restart, an OOM, a dev code-reload on the in-process
# :async adapter), so ChatJob's rescue/ensure never marked it errored and
# the UI shows "Working…" forever. Generous on purpose: there is no
# per-turn heartbeat, so the window must sit comfortably above the longest
# real turn or a still-running turn would be reaped (and its freed
# composer would admit a concurrent turn against the live process).
Rails.application.config.x.agent.stalled_turn_window =
  ENV.fetch("METIS_STALLED_TURN_MINUTES", "120").to_i.minutes

# Canonical per-provider metadata — the one place each provider's display
# label and API-key env var live, keyed by pi's provider id. Both fields
# are optional and independent: `openai-codex` authenticates via the
# ChatGPT backend (no key), and keyless providers fall back to a titleized
# label. Ids and env var names mirror pi's own conventions
# (https://pi.dev/docs/latest/providers) so the same env that runs pi
# locally works for Metis.
#
#   :label -> Agent::ModelCatalogSync seeds LlmProvider#label on first sync
#   :env   -> the env var the provider's API key is read from (below)
Rails.application.config.x.agent.provider_metadata = {
  "anthropic"    => { label: "Anthropic",   env: "ANTHROPIC_API_KEY" },
  "openai"       => { label: "OpenAI",       env: "OPENAI_API_KEY" },
  "openai-codex" => { label: "OpenAI Codex" },
  "google"       => { label: "Google",       env: "GEMINI_API_KEY" },
  "deepseek"     => { label: "DeepSeek",      env: "DEEPSEEK_API_KEY" },
  "mistral"      => { env: "MISTRAL_API_KEY" },
  "groq"         => { env: "GROQ_API_KEY" },
  "cerebras"     => { env: "CEREBRAS_API_KEY" },
  "xai"          => { env: "XAI_API_KEY" },
  "openrouter"   => { env: "OPENROUTER_API_KEY" },
  "together"     => { env: "TOGETHER_API_KEY" },
  "fireworks"    => { env: "FIREWORKS_API_KEY" },
  "huggingface"  => { env: "HF_TOKEN" }
}.freeze

# Per-provider API keys, read from the environment. A conversation's
# provider id is matched against this map and the key is passed to pi as
# --api-key. A shared, deployment-level resource — Metis has no per-user
# keys. Only providers with a configured (non-blank) key end up here.
Rails.application.config.x.agent.api_keys =
  Rails.application.config.x.agent.provider_metadata.filter_map do |provider, meta|
    [ provider, ENV[meta[:env]] ] if meta[:env]
  end.to_h.compact_blank

# Web-search backend for the agent's `web_search` tool (the web-tools pi
# extension). A shared, deployment-level resource — no per-user keys. The
# extension picks the first configured provider (Serper > Brave > SearXNG),
# and falls back to keyless DuckDuckGo when none is set. DuckDuckGo
# rate-limits datacenter IPs, so configure Serper (https://serper.dev) or
# Brave (https://brave.com/search/api/) for reliable search from the sandbox
# runtimes. Plumbed into the sandbox by Agent::Runtime::Base#sandbox_env.
Rails.application.config.x.agent.serper_api_key = ENV["SERPER_API_KEY"].presence
Rails.application.config.x.agent.brave_search_api_key = ENV["BRAVE_SEARCH_API_KEY"].presence
Rails.application.config.x.agent.searxng_url = ENV["SEARXNG_URL"].presence
