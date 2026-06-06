# LLM observability

Metis records what every agent turn cost — model, tokens, and dollars — and
can export each turn as an OpenTelemetry trace to
[Langfuse](https://langfuse.com) (or any OTLP backend) for dashboards,
per-user/team cost breakdowns, and trace drill-down.

There are two layers, usable independently:

1. **Native capture (always on).** Each finished turn persists its usage onto
   the assistant `Message`: `input_tokens`, `output_tokens`,
   `cache_read_tokens`, **`cost`** (USD), and **`model_key`** (the model that
   served the turn). Cost and model come straight from pi — pi prices each
   turn itself and returns the figure on the `get_session_stats` RPC, so
   Metis multiplies nothing. The per-message footer shows them.
2. **Langfuse export (opt-in).** When enabled, `ChatJob` emits one OTel trace
   per turn via `Observability::LangfuseTrace`.

## Where the numbers come from

pi reports **cumulative** session totals (tokens and cost) on
`get_session_stats`. `ChatJob#turn_usage_columns` takes each turn's share as
the rise over what earlier messages already account for — the same delta
approach used for tokens, applied to cost. `model_key` is snapshotted per
message so historical cost stays correctly attributed when a conversation
switches models mid-thread (`Conversation#agent_model` only holds the latest).

Tokens, cost, and model are captured independently: a provider that returns no
usage (e.g. Ollama — pi omits stats entirely, see
[earendil-works/pi#5386](https://github.com/earendil-works/pi/issues/5386))
still records its model, and an absent cost never suppresses tokens. The
adapter's `capture_stats` rescues to `nil`, so a stats failure degrades the
turn's numbers without ever crashing the turn the user already saw stream.

> **Accuracy note.** Summing per-message cost slightly *undercounts* a
> session: pi does not attribute compaction overhead to a message
> ([discussion #4123](https://github.com/earendil-works/pi/discussions/4123)).
> The authoritative session total is pi's cumulative `cost`; treat per-message
> cost as attribution detail.

## Enabling Langfuse

Set the keys (from a Langfuse project) and turn it on:

```
METIS_LANGFUSE_ENABLED=1
LANGFUSE_PUBLIC_KEY=pk-lf-…
LANGFUSE_SECRET_KEY=sk-lf-…
LANGFUSE_HOST=https://cloud.langfuse.com   # or your self-hosted URL
```

`config/initializers/observability.rb` configures an OTLP exporter pointed at
`<host>/api/public/otel/v1/traces` (Basic auth from the key pair) only when
enabled — a deployment that leaves it off loads none of the OpenTelemetry
stack (the gems are `require: false` in the `Gemfile`).

### What a trace looks like

One OTel trace per turn, shaped for Langfuse's observation model:

- **`metis.turn`** (root, `langfuse.observation.type=agent`) — carries
  `session.id` = conversation id and `user.id` for grouping, plus team and
  runtime metadata. A conversation's turns share a `session.id`, so Langfuse
  threads them into one session.
- **`metis.generation`** (`…=generation`) — the turn's `gen_ai.usage.*`
  tokens and `gen_ai.usage.cost`, tagged with the model.
- **`metis.tool.<name>`** (`…=tool`) — one per tool call.

Span timestamps use the message's `started_at`/`finished_at`, so latency is
preserved even though the trace is emitted after the turn finishes.

### Content governance

`Message#content` and `#reasoning` are Active Record-encrypted. By default the
export is **metadata-only** — model, tokens, cost, latency, tool names — and
sends no prompt/completion or tool I/O text. Set
`METIS_LANGFUSE_INCLUDE_CONTENT=1` to include it, and do that only against a
Langfuse instance you trust with that data (self-hosted, typically).

Export never raises into a turn: `LangfuseTrace.record_turn` rescues and logs,
matching the "observability is reporting, not the turn itself" rule the
adapter's stats capture follows.

## Why not pi's own OTel?

pi planned native OpenTelemetry/Langfuse export (the `0123` task epic) but it
never merged — there is no pi env var to flip. pi *does* expose the usage and
cost we need over its RPC, so Metis emits the spans itself from `ChatJob`,
where the per-turn numbers already live.
