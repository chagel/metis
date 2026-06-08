require "test_helper"

class WorkflowRunTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "wfr-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @team = @user.personal_team
  end

  def new_run(**attrs)
    conversation = attrs.delete(:conversation) || @user.conversations.create!
    @team.workflow_runs.create!(conversation: conversation, **attrs)
  end

  test "defaults to pending" do
    assert new_run.pending?
  end

  test "active scope spans pending, running, awaiting_approval only" do
    pending  = new_run
    running  = new_run.tap(&:running!)
    awaiting = new_run.tap(&:awaiting_approval!)
    new_run.tap(&:completed!)
    new_run.tap(&:cancelled!)

    assert_equal [ pending, running, awaiting ].map(&:id).sort,
                 @team.workflow_runs.active.pluck(:id).sort
  end

  test "awaiting scope returns only gated runs" do
    new_run
    awaiting = new_run.tap(&:awaiting_approval!)
    assert_equal [ awaiting ], @team.workflow_runs.awaiting.to_a
  end

  test "one run per conversation" do
    conversation = @user.conversations.create!
    new_run(conversation: conversation)
    assert_raises(ActiveRecord::RecordNotUnique) do
      # Skip the model uniqueness path to prove the DB index enforces it.
      @team.workflow_runs.create!(conversation_id: conversation.id)
    end
  end

  test "conversation exposes its run via has_one" do
    conversation = @user.conversations.create!
    run = new_run(conversation: conversation)
    assert_equal run, conversation.reload.workflow_run
  end

  test "destroying the conversation destroys the run" do
    conversation = @user.conversations.create!
    new_run(conversation: conversation)
    assert_difference -> { WorkflowRun.count }, -1 do
      conversation.destroy
    end
  end

  test "workflow is optional (ad-hoc run)" do
    assert new_run(workflow: nil).valid?
  end
end
