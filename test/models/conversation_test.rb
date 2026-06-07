require "test_helper"
require "turbo/broadcastable/test_helper"

class ConversationTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include Turbo::Broadcastable::TestHelper

  setup do
    @user = User.create!(email: "conv@example.com", password: "password123")
    @conversation = @user.conversations.create!
  end

  test "a conversation defaults its team to the creator's personal team" do
    assert_equal @user.personal_team, @conversation.team
  end

  test "turn_in_progress? is false with no in-flight assistant message" do
    refute @conversation.turn_in_progress?
  end

  test "turn_in_progress? is true while an assistant message is pending or streaming" do
    message = @conversation.messages.create!(role: :assistant, content: "", streaming_status: :pending)
    assert @conversation.turn_in_progress?

    message.update!(streaming_status: :streaming)
    assert @conversation.turn_in_progress?

    message.update!(streaming_status: :done)
    refute @conversation.turn_in_progress?
  end

  test "the database forbids two in-flight assistant messages per conversation" do
    @conversation.messages.create!(role: :assistant, content: "", streaming_status: :pending)

    assert_raises(ActiveRecord::RecordNotUnique) do
      @conversation.messages.create!(role: :assistant, content: "", streaming_status: :streaming)
    end
  end

  test "a finished assistant message frees the next turn" do
    @conversation.messages.create!(role: :assistant, content: "done", streaming_status: :done)

    assert_nothing_raised do
      @conversation.messages.create!(role: :assistant, content: "", streaming_status: :pending)
    end
  end

  test "forked? and needs_history_replay? track provenance and session state" do
    source = @user.conversations.create!
    message = source.messages.create!(role: :user, content: "q", streaming_status: :done)

    refute @conversation.forked?
    refute @conversation.needs_history_replay?

    @conversation.update!(forked_from_message: message)
    assert @conversation.forked?
    assert @conversation.needs_history_replay?, "forked, no session, not pending → replay"

    @conversation.update!(fork_pending: true)
    refute @conversation.needs_history_replay?, "owes a real session copy → no replay"

    @conversation.update!(fork_pending: false, backend_session_id: "sess-1")
    refute @conversation.needs_history_replay?, "has its own session → no replay"
  end

  test "forked_from_conversation resolves the source and nils out when it is gone" do
    source = @user.conversations.create!
    message = source.messages.create!(role: :user, content: "q", streaming_status: :done)
    @conversation.update!(forked_from_message: message)

    assert_equal source, @conversation.forked_from_conversation

    source.destroy # cascade-deletes its messages; the FK nullifies our pointer
    assert_nil @conversation.reload.forked_from_conversation
    refute @conversation.forked?
  end

  test "model_label reads from settings before a turn runs" do
    conversation = @user.conversations.create!(
      settings: { "provider" => "openai", "model" => "gpt-5.5" }
    )
    assert_equal "gpt-5.5", conversation.model_label
  end

  test "model_label prefers the model pi resolved" do
    conversation = @user.conversations.create!(
      settings: { "model" => "gpt-5.5" },
      agent_model: { "provider" => "openai-codex", "name" => "GPT-5.5" }
    )
    assert_equal "GPT-5.5", conversation.model_label
  end

  test "model_label and runtime_label are nil when nothing is known" do
    assert_nil @conversation.model_label
    assert_nil @conversation.runtime_label
  end

  test "configured_model/provider prefer the conversation's own settings" do
    conversation = @user.conversations.create!(
      settings: { "provider" => "openai", "model" => "gpt-5.5" }
    )
    assert_equal "gpt-5.5", conversation.configured_model
    assert_equal "openai", conversation.configured_provider
  end

  test "configured_model/provider fall back to the deployment default" do
    agent = Rails.application.config.x.agent
    prev_model, prev_provider = agent.model, agent.provider
    agent.model = "anthropic/claude-opus-4-8"
    agent.provider = "anthropic"
    @conversation.update!(settings: {})

    assert_equal "anthropic/claude-opus-4-8", @conversation.configured_model
    assert_equal "anthropic", @conversation.configured_provider
  ensure
    agent.model = prev_model
    agent.provider = prev_provider
  end

  test "runtime_label is the runtime the last turn ran on" do
    @conversation.update!(runtime_state: { "runtime" => "e2b", "sandbox_id" => "sbx-7" })
    assert_equal "e2b", @conversation.runtime_label
  end

  test "request_cancel! stamps cancel_requested_at" do
    assert_nil @conversation.cancel_requested_at
    @conversation.request_cancel!
    assert_not_nil @conversation.reload.cancel_requested_at
  end

  test "destroying a conversation kills its paused E2B sandbox" do
    # E2B keeps paused sandboxes indefinitely — without the destroy hook
    # every deleted conversation would leave a sandbox on E2B's servers
    # forever (docs/coding-runtime.md).
    @conversation.update_column(:e2b_sandbox_id, "sbx-doomed")
    killed_with = nil

    with_stub(Agent::Runtime::E2b, :kill_sandbox, ->(id) { killed_with = id }) do
      @conversation.destroy
    end

    assert_equal "sbx-doomed", killed_with
  end

  test "archive! stamps archived_at and unarchive! clears it" do
    refute @conversation.archived?
    assert Conversation.active.exists?(@conversation.id)
    refute Conversation.archived.exists?(@conversation.id)

    @conversation.archive!
    assert @conversation.archived?
    assert_not_nil @conversation.archived_at
    refute Conversation.active.exists?(@conversation.id)
    assert Conversation.archived.exists?(@conversation.id)

    @conversation.unarchive!
    refute @conversation.archived?
    assert_nil @conversation.archived_at
  end

  test "archive! is idempotent and does not move archived_at on a second call" do
    @conversation.archive!
    first_stamp = @conversation.archived_at
    travel 1.minute do
      @conversation.archive!
      assert_equal first_stamp, @conversation.reload.archived_at
    end
  end

  test "unarchive! is a no-op when the conversation is not archived" do
    assert_nothing_raised { @conversation.unarchive! }
    refute @conversation.archived?
  end

  test "star! stamps starred_at and unstar! clears it" do
    refute @conversation.starred?
    refute Conversation.starred.exists?(@conversation.id)

    @conversation.star!
    assert @conversation.starred?
    assert_not_nil @conversation.starred_at
    assert Conversation.starred.exists?(@conversation.id)

    @conversation.unstar!
    refute @conversation.starred?
    assert_nil @conversation.starred_at
    refute Conversation.starred.exists?(@conversation.id)
  end

  test "star! is idempotent and does not move starred_at on a second call" do
    @conversation.star!
    first_stamp = @conversation.starred_at
    travel 1.minute do
      @conversation.star!
      assert_equal first_stamp, @conversation.reload.starred_at
    end
  end

  test "unstar! is a no-op when the conversation is not starred" do
    assert_nothing_raised { @conversation.unstar! }
    refute @conversation.starred?
  end

  test "destroying a conversation with no sandbox is a no-op for E2B" do
    called = false
    with_stub(Agent::Runtime::E2b, :kill_sandbox, ->(_id) { called = true }) do
      @conversation.destroy
    end
    # kill_sandbox itself is the guard against blank ids; it gets the
    # nil and short-circuits.
    assert called, "still invoked so the guard lives in one place"
  end

  test "generate_title_async! enqueues the job when title is blank" do
    assert_enqueued_with(job: GenerateConversationTitleJob, args: [ @conversation.id ]) do
      @conversation.generate_title_async!
    end
  end

  test "generate_title_async! is a no-op once a title exists" do
    @conversation.update!(title: "Already named")
    assert_no_enqueued_jobs only: GenerateConversationTitleJob do
      @conversation.generate_title_async!
    end
  end

  test "apply_generated_title! writes the cleaned title and bumps updated_at" do
    @conversation.messages.create!(role: :user, content: "first", streaming_status: :done)
    travel 1.minute do
      assert_changes -> { @conversation.reload.updated_at } do
        @conversation.apply_generated_title!("  Rails 8 Setup  ")
      end
    end
    assert_equal "Rails 8 Setup", @conversation.title
  end

  test "apply_generated_title! truncates oversized titles to TITLE_MAX" do
    @conversation.messages.create!(role: :user, content: "first", streaming_status: :done)
    @conversation.apply_generated_title!("A" * 200)
    assert_equal Conversation::TITLE_MAX, @conversation.title.length
  end

  test "apply_generated_title! falls back to the first user message when LLM returned nothing" do
    @conversation.messages.create!(role: :user, content: "How do I do X?", streaming_status: :done)
    @conversation.apply_generated_title!(nil)
    assert_equal "How do I do X?", @conversation.title
  end

  test "apply_generated_title! is a no-op when both the LLM and fallback are empty" do
    @conversation.apply_generated_title!(nil)
    assert_nil @conversation.title
  end

  test "shared? is false until a share token is minted" do
    refute @conversation.shared?
    @conversation.generate_share_token!
    assert @conversation.shared?
  end

  test "generate_share_token! returns the same token on repeat calls" do
    token = @conversation.generate_share_token!
    assert_equal token, @conversation.generate_share_token!
  end

  test "revoke_share! clears the share token" do
    @conversation.generate_share_token!
    @conversation.revoke_share!
    refute @conversation.shared?
    assert_nil @conversation.reload.share_token
  end

  test "shared scope returns only conversations with a share token" do
    shared = @user.conversations.create!(title: "shared")
    shared.generate_share_token!
    @user.conversations.create!(title: "private")

    assert_equal [ shared ], Conversation.shared.to_a
  end

  test "broadcast_shared_to_team! lights the shared tab on the team stream" do
    team = Team.create!(name: "Acme")
    @user.memberships.create!(team: team, role: :owner)
    conversation = @user.conversations.create!(team: team, title: "Shared")

    assert_turbo_stream_broadcasts(team, count: 1) do
      conversation.broadcast_shared_to_team!
    end
  end

  test "replayable_history returns prior user and assistant turns in order" do
    @conversation.messages.create!(role: :user, content: "first", streaming_status: :done)
    @conversation.messages.create!(role: :assistant, content: "reply", streaming_status: :done)
    # In-flight turn — the live prompt plus its pending assistant.
    @conversation.messages.create!(role: :user, content: "current ask", streaming_status: :done)
    @conversation.messages.create!(role: :assistant, content: "", streaming_status: :pending)

    contents = @conversation.replayable_history.map(&:content)
    assert_equal [ "first", "reply" ], contents
  end

  test "replayable_history excludes the current user message and its pending assistant" do
    @conversation.messages.create!(role: :user, content: "current ask", streaming_status: :done)
    @conversation.messages.create!(role: :assistant, content: "", streaming_status: :pending)

    assert_empty @conversation.replayable_history
  end

  test "replayable_history ignores tool and system messages" do
    @conversation.messages.create!(role: :user, content: "do it", streaming_status: :done)
    @conversation.messages.create!(role: :tool, content: "tool noise", streaming_status: :done)
    @conversation.messages.create!(role: :system, content: "system note", streaming_status: :done)
    @conversation.messages.create!(role: :assistant, content: "done", streaming_status: :done)
    @conversation.messages.create!(role: :user, content: "current", streaming_status: :done)

    assert_equal [ "do it", "done" ], @conversation.replayable_history.map(&:content)
  end
end
