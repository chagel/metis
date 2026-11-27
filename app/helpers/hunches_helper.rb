module HunchesHelper
  # The Hunches tab's badge: how many are waiting.
  def ready_hunches_count
    @ready_hunches_count ||= Hunch.for(current_user, current_team).ready.count
  end

  def direction_explored(direction)
    if direction.last_explored_at
      t("directions.explored", time: time_ago_in_words(direction.last_explored_at))
    else
      t("directions.not_explored")
    end
  end
end
