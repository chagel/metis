require "test_helper"

class ApplicationJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "enqueue inside a transaction is deferred until commit" do
    ActiveRecord::Base.transaction do
      ChatJob.perform_later(1, 2, 3)
      assert_no_enqueued_jobs
    end

    assert_enqueued_with(job: ChatJob, args: [ 1, 2, 3 ])
  end

  test "enqueue inside a rolled-back transaction is dropped" do
    ActiveRecord::Base.transaction do
      ChatJob.perform_later(1, 2, 3)
      raise ActiveRecord::Rollback
    end

    assert_no_enqueued_jobs
  end
end
