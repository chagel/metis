class ApplicationJob < ActiveJob::Base
  # Solid Queue lives in a separate database, so an enqueue inside an app-DB
  # transaction is visible to workers before the rows it references commit —
  # a worker can claim the job and RecordNotFound (e.g. a routine's ChatJob
  # enqueued under Routine#fire_scheduled!'s with_lock). Defer the enqueue
  # until the surrounding transaction commits.
  self.enqueue_after_transaction_commit = true

  # Automatically retry jobs that encountered a deadlock
  # retry_on ActiveRecord::Deadlocked

  # Most jobs are safe to ignore if the underlying records are no longer available
  # discard_on ActiveJob::DeserializationError
end
