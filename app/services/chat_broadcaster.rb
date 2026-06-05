# Maps Agent::UiEvent objects to Turbo Stream broadcasts on a
# conversation's stream. Owns the live DOM; ChatJob owns persistence.
class ChatBroadcaster
  include ActionView::RecordIdentifier

  def initialize(conversation, assistant_message)
    @conversation = conversation
    @message = assistant_message
    @text = +""
    @tools = {}
  end

  def handle(event)
    case event.type
    when :runtime_status    then update_runtime_status(event)
    when :message_started   then clear_runtime_phase
    when :text_delta        then append_text(event[:delta])
    when :reasoning_delta   then append_reasoning(event[:delta])
    when :tool_call_started then start_tool(event)
    when :tool_call_progress, :tool_call_finished then update_tool(event)
    when :turn_finished     then finish
    when :error             then show_error(event[:message])
    end
  end

  # Called by ChatJob when the run fails before/outside the event stream.
  def fail(message)
    show_error(message)
    finish
  end

  # Appends the "running" dot to this conversation's sidebar row.
  # The dot is broadcast on the user's stream so it appears even when
  # the user is viewing a different conversation.
  def start_sidebar_indicator
    Turbo::StreamsChannel.broadcast_append_to(
      @conversation.user,
      target: dom_id(@conversation),
      html: sidebar_indicator_html
    )
  end

  # Removes the sidebar running dot once the turn ends or errors.
  def stop_sidebar_indicator
    Turbo::StreamsChannel.broadcast_remove_to(
      @conversation.user,
      target: dom_id(@conversation, :running)
    )
  end

  # Called by ChatJob once a turn's token/context usage is persisted:
  # repaints the conversation's context meter and this message's token
  # footer.
  def refresh_usage
    Turbo::StreamsChannel.broadcast_replace_to(
      @conversation,
      target: dom_id(@conversation, :context),
      partial: "conversations/context_meter",
      locals: { conversation: @conversation }
    )
    Turbo::StreamsChannel.broadcast_update_to(
      @conversation,
      target: "#{base_id}_meta",
      html: ApplicationController.helpers.message_meta(@message)
    )
  end

  # Swap the composer's Stop button back to Send once the turn ends.
  def refresh_composer
    Turbo::StreamsChannel.broadcast_replace_to(
      @conversation,
      target: "composer_actions",
      partial: "conversations/composer_actions",
      locals: { conversation: @conversation }
    )
  end

  # Replaces into an always-rendered placeholder, so the first strip
  # works the same as subsequent updates.
  def refresh_artifacts
    Turbo::StreamsChannel.broadcast_replace_to(
      @conversation,
      target: "#{base_id}_artifacts",
      partial: "messages/artifacts",
      locals: { message: @message }
    )
  end

  # Called by ChatJob once the turn is persisted: re-renders the
  # reasoning/tools disclosure from the saved message, which collapses
  # it (the turn is now done) — or removes it if there was neither.
  def collapse_activity
    Turbo::StreamsChannel.broadcast_replace_to(
      @conversation,
      target: "#{base_id}_activity",
      partial: "messages/activity",
      locals: { message: @message }
    )
  end

  private

  def base_id = dom_id(@message)

  # Accumulate the streamed text and re-render the whole body as Markdown.
  # An innerHTML update (not append) keeps partial Markdown — open code
  # fences, half-built tables — rendering correctly as more text arrives.
  #
  # Skip only empty deltas, never `blank?` ones: some models stream block
  # separators as standalone whitespace deltas ("\n\n", " "), and dropping
  # those fuses Markdown blocks live (headings, tables) while the persisted
  # content — which keeps every delta — renders fine on refresh.
  def append_text(delta)
    return if delta.to_s.empty?

    @text << delta
    Turbo::StreamsChannel.broadcast_update_to(
      @conversation, target: "#{base_id}_body",
      html: ApplicationController.helpers.markdown(@text)
    )
  end

  def append_reasoning(delta)
    return if delta.to_s.empty?

    broadcast_append(target: "#{base_id}_reasoning", html: ERB::Util.html_escape(delta))
  end

  def start_tool(event)
    collapse_previous_tool
    broadcast(:append, target: "#{base_id}_tools", partial: "messages/tool_call",
                       locals: record_tool(event, status: :running).merge(open: true))
  end

  def update_tool(event)
    status = event.type == :tool_call_finished ? :done : :running
    is_latest = event[:tool_call_id] == @tools.keys.last
    broadcast(:replace, target: "tool_#{event[:tool_call_id]}", partial: "messages/tool_call",
                        locals: record_tool(event, status: status).merge(open: is_latest))
  end

  # Re-render the previously-latest tool (if any) collapsed, so only the
  # newest tool stays expanded while a turn streams.
  def collapse_previous_tool
    prev_id = @tools.keys.last
    return unless prev_id

    prev = @tools[prev_id]
    status = prev[:output].present? ? :done : :running
    broadcast(:replace, target: "tool_#{prev_id}", partial: "messages/tool_call",
                        locals: {
                          tool_call_id: prev_id, name: prev[:name], args: prev[:args],
                          output: prev[:output], is_error: prev[:is_error],
                          skill_slug: prev[:skill_slug],
                          status: status, open: false
                        })
  end

  def finish
    Turbo::StreamsChannel.broadcast_remove_to(@conversation, target: "#{base_id}_indicator")
  end

  # Show the runtime's provisioning phase ("Creating sandbox", …) in the same
  # indicator the elapsed timer lives in — these arrive before pi's first event.
  def update_runtime_status(event)
    @phase_shown = true
    broadcast_indicator(phase: event[:message])
  end

  # pi has started producing output, so provisioning is done — drop the phase
  # label back to the plain elapsed timer. No-op unless a phase was shown.
  def clear_runtime_phase
    return unless @phase_shown

    @phase_shown = false
    broadcast_indicator(phase: nil)
  end

  def broadcast_indicator(phase:)
    broadcast(:replace, target: "#{base_id}_indicator",
                        partial: "messages/streaming_indicator",
                        locals: { message: @message, phase: phase })
  end

  # Append into the message card, not the body — the body's innerHTML is
  # replaced on every text delta, which would otherwise swallow the error.
  def show_error(message)
    broadcast(:append, target: base_id, partial: "messages/error",
                       locals: { message: message })
  end

  # Merge an event into the tool call's accumulated state (keyed by id)
  # and return the full set of `messages/tool_call` locals.
  #
  # tool_call_progress / tool_call_finished carry no name or args — those
  # arrive only on tool_call_started — so without accumulating, replacing
  # the card on a later event would blank the tool name and command. The
  # returned hash always carries every local so the partial never sees
  # an undefined variable.
  def record_tool(event, status:)
    call = (@tools[event[:tool_call_id]] ||= {})
    call[:name]       = event[:name]       if event.data.key?(:name)
    call[:args]       = event[:args]       if event.data.key?(:args)
    call[:output]     = event[:output]     if event.data.key?(:output)
    call[:is_error]   = event[:is_error]   if event.data.key?(:is_error)
    call[:skill_slug] = event[:skill_slug] if event.data.key?(:skill_slug)
    {
      tool_call_id: event[:tool_call_id],
      name: call[:name],
      args: call[:args],
      output: call[:output],
      is_error: call[:is_error],
      skill_slug: call[:skill_slug],
      status: status
    }
  end

  def broadcast_append(target:, html:)
    Turbo::StreamsChannel.broadcast_append_to(@conversation, target: target, html: html)
  end

  def broadcast(action, target:, partial:, locals:)
    Turbo::StreamsChannel.public_send(
      "broadcast_#{action}_to", @conversation, target: target, partial: partial, locals: locals
    )
  end

  def sidebar_indicator_html
    %(<span class="convo-running" id="#{dom_id(@conversation, :running)}" aria-label="Running"></span>)
  end
end
