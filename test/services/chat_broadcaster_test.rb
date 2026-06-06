require "test_helper"

class ChatBroadcasterTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "bc@example.com", password: "password123")
    conversation = user.conversations.create!
    message = conversation.messages.create!(role: :assistant, content: "", streaming_status: :streaming)
    @broadcaster = ChatBroadcaster.new(conversation, message)
  end

  def event(type, **data)
    Agent::UiEvent.new(type, data: data)
  end

  test "a tool call keeps its name and args when a later event updates it" do
    @broadcaster.send(:record_tool,
      event(:tool_call_started, tool_call_id: "t1", name: "bash", args: { "command" => "ls" }),
      status: :running)

    locals = @broadcaster.send(:record_tool,
      event(:tool_call_finished, tool_call_id: "t1", output: "ok", is_error: false),
      status: :done)

    assert_equal "bash", locals[:name]
    assert_equal({ "command" => "ls" }, locals[:args])
    assert_equal "ok", locals[:output]
    assert_equal :done, locals[:status]
  end

  test "record_tool always returns every tool_call partial local" do
    locals = @broadcaster.send(:record_tool,
      event(:tool_call_started, tool_call_id: "t1", name: "bash", args: {}),
      status: :running)

    assert_equal %i[tool_call_id name args output is_error skill_slug status].sort, locals.keys.sort
  end

  test "a whitespace-only text delta is kept, not dropped as blank" do
    @broadcaster.handle(event(:text_delta, delta: "## Heading"))
    @broadcaster.handle(event(:text_delta, delta: "\n\n"))
    @broadcaster.handle(event(:text_delta, delta: "Body text"))

    # The block separator survives so Heading/Body don't fuse live.
    assert_equal "## Heading\n\nBody text", @broadcaster.instance_variable_get(:@pending)
  end

  test "an empty text delta is skipped" do
    @broadcaster.handle(event(:text_delta, delta: ""))
    @broadcaster.handle(event(:text_delta, delta: nil))

    assert_equal "", @broadcaster.instance_variable_get(:@pending)
  end

  test "message_finished adopts pi's complete text over a short delta stream" do
    # openai ends the delta stream a few chars short of the message's real
    # text; the message_end content is authoritative.
    @broadcaster.handle(event(:text_delta, delta: "Hi. What do you nee"))
    @broadcaster.handle(event(:message_finished, id: "m1", content: "Hi. What do you need?"))

    assert_equal [ "Hi. What do you need?" ], @broadcaster.instance_variable_get(:@segments)
    assert_equal "", @broadcaster.instance_variable_get(:@pending)
  end

  test "a runtime_status event renders the phase into the indicator" do
    @broadcaster.handle(event(:runtime_status, phase: :resuming, message: "Resuming sandbox"))

    assert @broadcaster.instance_variable_get(:@phase_shown),
           "a phase was shown, so the first pi event should clear it"
  end

  test "message_started clears a shown runtime phase back to the timer" do
    @broadcaster.handle(event(:runtime_status, phase: :creating, message: "Creating sandbox"))
    @broadcaster.handle(event(:message_started, id: "m1", role: "assistant"))

    refute @broadcaster.instance_variable_get(:@phase_shown), "phase cleared once pi starts"
  end

  test "message_started is a no-op when no runtime phase was shown" do
    assert_nothing_raised do
      @broadcaster.handle(event(:message_started, id: "m1", role: "assistant"))
    end
    refute @broadcaster.instance_variable_get(:@phase_shown)
  end

  test "record_tool carries skill_slug from started through later events" do
    @broadcaster.send(:record_tool,
      event(:tool_call_started, tool_call_id: "t1", name: "bash",
                                args: { "command" => "cat .pi/skills/eli5/SKILL.md" },
                                skill_slug: "eli5"),
      status: :running)

    locals = @broadcaster.send(:record_tool,
      event(:tool_call_finished, tool_call_id: "t1", output: "ok", is_error: false),
      status: :done)

    assert_equal "eli5", locals[:skill_slug]
  end
end
