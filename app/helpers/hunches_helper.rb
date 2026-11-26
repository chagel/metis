module HunchesHelper
  def direction_explored(direction)
    if direction.last_explored_at
      t("directions.explored", time: time_ago_in_words(direction.last_explored_at))
    else
      t("directions.not_explored")
    end
  end
end
