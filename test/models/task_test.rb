require "test_helper"

class TaskTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "task-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @team = @user.personal_team
    @run = @team.workflow_runs.create!(conversation: @user.conversations.create!)
  end

  test "defaults: pending status, auto gate" do
    task = @run.tasks.create!(position: 0)
    assert task.pending?
    assert task.auto?
  end

  test "result_detail is nil when it merely echoes the summary" do
    task = @run.tasks.create!(position: 0,
                              result: { "summary" => "done", "detail" => "done" })
    assert_nil task.result_detail

    task.update!(result: { "summary" => "done", "detail" => "Changed retry.rb; committed abc123." })
    assert_equal "Changed retry.rb; committed abc123.", task.result_detail
  end

  test "position is required and unique per run" do
    @run.tasks.create!(position: 0)
    assert_raises(ActiveRecord::RecordNotUnique) do
      @run.tasks.create!(position: 0)
    end
  end

  test "the same position is free in another run" do
    other = @team.workflow_runs.create!(conversation: @user.conversations.create!)
    @run.tasks.create!(position: 0)
    assert other.tasks.create!(position: 0).persisted?
  end

  test "next_pending returns the lowest-position pending task" do
    @run.tasks.create!(position: 0, status: :completed)
    second = @run.tasks.create!(position: 1)
    @run.tasks.create!(position: 2)
    assert_equal second, @run.tasks.next_pending.first
  end

  test "tasks are ordered by position through the association" do
    @run.tasks.create!(position: 2, name: "c")
    @run.tasks.create!(position: 0, name: "a")
    @run.tasks.create!(position: 1, name: "b")
    assert_equal %w[a b c], @run.tasks.reload.map(&:name)
  end

  test "destroying the run destroys its tasks" do
    @run.tasks.create!(position: 0)
    assert_difference -> { Task.count }, -1 do
      @run.destroy
    end
  end

  test "purging the assistant message nullifies the audit link, keeps the task" do
    message = @run.conversation.messages.create!(role: :assistant, content: "", streaming_status: :done)
    task = @run.tasks.create!(position: 0, assistant_message: message)

    assert_no_difference -> { Task.count } do
      message.destroy
    end
    assert_nil task.reload.assistant_message_id
  end

  test "gate enum exposes approval steps" do
    task = @run.tasks.create!(position: 0, gate: :approval)
    assert task.approval?
  end
end
