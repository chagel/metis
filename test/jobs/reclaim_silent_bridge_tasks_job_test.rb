require "test_helper"

class ReclaimSilentBridgeTasksJobTest < ActiveJob::TestCase
  setup do
    @user = User.create!(email: "rsb-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @team = @user.personal_team
  end

  test "reclaims a claim silent past the TTL; the task is re-claimable" do
    run = dispatch_run
    task = Task.claim_next_for(@user, client: "mikes-mbp")

    travel 16.minutes do
      ReclaimSilentBridgeTasksJob.perform_now
    end

    task.reload
    assert task.running?
    assert_nil task.claimed_by_user_id
    assert_nil task.claimed_by
    assert_equal 1, task.reclaims_count
    assert_equal "reclaim", task.progress.last["kind"]
    assert_match(/went silent/, task.progress.last["text"])
    assert run.reload.awaiting_local?, "the run stays parked, not failed"
    assert_equal task, Task.claim_next_for(@user, client: "other-machine")
  end

  test "never fires while events keep arriving" do
    dispatch_run
    task = Task.claim_next_for(@user, client: "mikes-mbp")

    travel 10.minutes do
      task.log_progress!({ "kind" => "log", "text" => "still working" })
    end
    travel 20.minutes do
      ReclaimSilentBridgeTasksJob.perform_now
    end

    assert_equal @user.id, task.reload.claimed_by_user_id
    assert_equal 0, task.reclaims_count
  end

  test "leaves unclaimed dispatched tasks alone — offline is just latency" do
    run = dispatch_run

    travel 2.hours do
      ReclaimSilentBridgeTasksJob.perform_now
    end

    task = run.tasks.first.reload
    assert task.running?
    assert_equal 0, task.reclaims_count
    assert run.reload.awaiting_local?
  end

  test "fails the task and run at the reclaim cap" do
    run = dispatch_run
    task = Task.claim_next_for(@user, client: "mikes-mbp")
    task.update!(reclaims_count: Rails.application.config.x.bridge.reclaim_cap)

    travel 16.minutes do
      ReclaimSilentBridgeTasksJob.perform_now
    end

    assert task.reload.failed?
    assert run.reload.failed?
    report = run.conversation.messages.where(kind: :local_report).last
    assert_match(/went silent/, report.content)
  end
end
