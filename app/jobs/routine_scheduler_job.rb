# Fires due scheduled routines. Wired in config/recurring.yml to run every
# minute (production). Best-effort per row — one failure is logged and the
# sweep continues. Mirrors ReapStalledTurnsJob.
class RoutineSchedulerJob < ApplicationJob
  queue_as :default

  def perform
    Routine.due.find_each do |routine|
      routine.fire_scheduled!
    rescue StandardError => e
      Rails.logger.error("RoutineSchedulerJob: routine #{routine.id} failed: #{e.class}: #{e.message}")
    end
  end
end
