# Runs one agent turn: streams the backend adapter's UiEvents, broadcasts
# them to the conversation, and persists the assistant message.
class ChatJob < ApplicationJob
  queue_as :default

  # How often (in streamed events) to poll for a cancellation request.
  CANCEL_POLL_INTERVAL = 15

  def perform(conversation_id, user_message_id, assistant_message_id)
    conversation = Conversation.find(conversation_id)
    user_message = Message.find(user_message_id)
    assistant_message = Message.find(assistant_message_id)
    # Copy the source's pi session in before the adapter reads
    # backend_session_id for --continue.
    Agent::ForkPreparer.prepare(conversation) if conversation.fork_pending?
    broadcaster = ChatBroadcaster.new(conversation, assistant_message)
    adapter = Agent::Adapters.for(conversation)

    run(conversation, user_message, assistant_message, broadcaster, adapter)
  rescue StandardError => e
    Rails.logger.error("ChatJob #{conversation_id} failed: #{e.class}: #{e.message}")
    fail_message(assistant_message, broadcaster, "The agent run failed.")
  ensure
    # Even on crash — the runtime already buffered what the agent wrote
    # before the stream raised.
    attach_artifacts(assistant_message, adapter, broadcaster) if adapter
  end

  private

  def run(conversation, user_message, assistant_message, broadcaster, adapter)
    assistant_message.update!(streaming_status: :streaming)
    broadcaster.start_sidebar_indicator
    text = +""
    reasoning = +""
    segments = []
    tools = {}
    errored = false
    canceled = false
    events = 0

    adapter.stream(user_message.content,
                   images: user_message.images, files: user_message.files) do |event|
      case event.type
      when :text_delta       then text << event[:delta].to_s
      when :reasoning_delta  then reasoning << event[:delta].to_s
      when :message_finished then segments << event[:content].to_s
      when :tool_call_started, :tool_call_progress, :tool_call_finished
        record_tool_call(tools, event)
      when :error            then errored = true
      end
      broadcaster.handle(event)

      events += 1
      if !canceled && (events % CANCEL_POLL_INTERVAL).zero? && cancel_requested?(conversation, assistant_message)
        adapter.abort
        canceled = true
      end
    end

    assistant_message.update!(
      content: scrub_null_bytes(final_text(segments, text)),
      reasoning: scrub_null_bytes(reasoning.presence),
      tool_calls: scrub_null_bytes(tools.values),
      streaming_status: final_status(canceled: canceled, errored: errored),
      finished_at: Time.current,
      **turn_usage_columns(conversation, adapter)
    )
    persist_session_id(conversation, adapter)
    persist_context_usage(conversation, adapter)
    persist_agent_model(conversation, adapter)
    persist_runtime(conversation, adapter)
    Observability::LangfuseTrace.record_turn(
      conversation: conversation, user_message: user_message, assistant_message: assistant_message
    )
    broadcaster.refresh_usage
    broadcaster.collapse_activity
    broadcaster.reveal_actions
    broadcaster.stop_sidebar_indicator
    broadcaster.refresh_composer
  end

  # Has the user asked to stop *this* turn? The flag is conversation-wide,
  # so it is scoped by time — a stamp from before the turn began (a stale
  # request, or a prior turn's) does not count.
  def cancel_requested?(conversation, assistant_message)
    started_at = assistant_message.started_at
    return false unless started_at

    cancel_time = Conversation.where(id: conversation.id).pick(:cancel_requested_at)
    cancel_time.present? && cancel_time > started_at
  end

  def final_status(canceled:, errored:)
    return :canceled if canceled
    return :errored if errored

    :done
  end

  # openai ends the delta stream a few chars short of the real text, which pi
  # delivers complete in message_end; fall back to the buffer if nothing finalized.
  def final_text(segments, streamed)
    finalized = segments.reject(&:blank?)
    finalized.any? ? finalized.join("\n\n") : streamed
  end

  # Accumulate one tool call across its started/progress/finished events,
  # keyed by id so progress and result land on the right entry.
  def record_tool_call(tools, event)
    call = (tools[event[:tool_call_id]] ||= { "tool_call_id" => event[:tool_call_id] })
    call["name"]       = event[:name]       if event.data.key?(:name)
    call["args"]       = event[:args]       if event.data.key?(:args)
    call["output"]     = event[:output]     if event.data.key?(:output)
    call["is_error"]   = event[:is_error]   if event.data.key?(:is_error)
    call["skill_slug"] = event[:skill_slug] if event.data.key?(:skill_slug)
    call["status"]     = event.type == :tool_call_finished ? "done" : "running"
  end

  # Record pi's session id so the next message resumes the same session.
  def persist_session_id(conversation, adapter)
    session_id = adapter.native_session_id
    return if session_id.blank? || session_id == conversation.backend_session_id

    conversation.update_column(:backend_session_id, session_id)
  end

  # This turn's usage, written onto the assistant message. pi reports
  # cumulative session totals, so each turn's share is the rise over what
  # earlier messages already account for. Tokens, cost, and model are
  # independent: a provider that returns no usage (pi omits stats, see
  # earendil-works/pi#5386) still records its model, and an absent cost
  # doesn't suppress tokens. Computed before this message's own rows count.
  def turn_usage_columns(conversation, adapter)
    token_deltas(conversation, adapter)
      .merge(cost_delta(conversation, adapter))
      .merge(model_key: adapter.model_info&.dig("id"))
      .compact
  end

  def token_deltas(conversation, adapter)
    totals = adapter.token_totals
    return {} if totals.blank?

    {
      input_tokens:      turn_delta(totals["input"],     conversation.messages.sum(:input_tokens)),
      output_tokens:     turn_delta(totals["output"],    conversation.messages.sum(:output_tokens)),
      cache_read_tokens: turn_delta(totals["cacheRead"], conversation.messages.sum(:cache_read_tokens))
    }
  end

  def cost_delta(conversation, adapter)
    total = adapter.cost_total
    return {} if total.nil?

    { cost: [ total.to_d - conversation.messages.sum(:cost), 0 ].max }
  end

  def turn_delta(total, prior)
    [ total.to_i - prior.to_i, 0 ].max
  end

  # Store the latest context-window snapshot for the conversation header.
  def persist_context_usage(conversation, adapter)
    usage = adapter.context_usage
    return if usage.blank?

    conversation.update_column(:context_usage, usage)
  end

  # Store the model pi resolved for the conversation (it can change if a
  # model is switched mid-conversation).
  def persist_agent_model(conversation, adapter)
    model = adapter.model_info
    return if model.blank? || model == conversation.agent_model

    conversation.update_column(:agent_model, model)
  end

  # Record where the turn ran — the runtime name and, for E2B, the
  # sandbox id — on the conversation.
  def persist_runtime(conversation, adapter)
    info = adapter.runtime_info
    return if info.blank? || info == conversation.runtime_state

    conversation.update_column(:runtime_state, info)
  end

  # Logged-not-raised — a storage hiccup must not crash recovery.
  def attach_artifacts(assistant_message, adapter, broadcaster)
    return if adapter.artifacts.blank?

    adapter.artifacts.each do |artifact|
      assistant_message.artifacts.attach(
        io: artifact[:io],
        filename: artifact[:filename],
        content_type: artifact[:content_type]
      )
    end
    broadcaster&.refresh_artifacts
  rescue StandardError => e
    Rails.logger.warn("Artifact attach failed for message #{assistant_message.id}: #{e.message}")
  end

  # Mark the turn errored after a crash. Reloads first to drop any
  # in-memory dirty attributes from a failed persist — otherwise the
  # recovery update flushes the same poisoned payload (e.g. a tool_calls
  # bag with a U+0000 byte) and rolls back too, leaving the message
  # frozen mid-turn.
  def fail_message(assistant_message, broadcaster, message)
    return unless assistant_message

    assistant_message.reload.update!(streaming_status: :errored, finished_at: Time.current)
    broadcaster&.fail(message)
    broadcaster&.stop_sidebar_indicator
    broadcaster&.refresh_composer
  rescue ActiveRecord::RecordNotFound
    # Message vanished while we were running — nothing to recover.
  end

  # PostgreSQL refuses to store U+0000 in text/jsonb columns. pi
  # occasionally emits one inside a tool call's payload (a binary leak
  # from a subprocess, a malformed file read). Strip them at the persist
  # boundary so a single stray byte doesn't sink a whole turn's output.
  def scrub_null_bytes(value)
    case value
    when nil    then nil
    when String then value.delete("\x00")
    when Array  then value.map { |v| scrub_null_bytes(v) }
    when Hash   then value.each_with_object({}) { |(k, v), h| h[scrub_null_bytes(k)] = scrub_null_bytes(v) }
    else value
    end
  end
end
