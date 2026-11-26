module Agent
  # Directions and hunches over pi's Extension UI channel (Agent::HostBridge),
  # scoped to the conversation's own user and team. Adding a direction is an
  # attended chat action; updating one and recording hunches are what the
  # foresight run does (Agent::RunPolicy limits those to it when unattended).
  # Never raises into the turn — a failure is { ok: false }.
  class ForesightManager
    def self.list(conversation, params) = new(conversation, params).list
    def self.add(conversation, params) = new(conversation, params).add
    def self.update(conversation, params) = new(conversation, params).update
    def self.record(conversation, params) = new(conversation, params).record

    def initialize(conversation, params)
      @conversation = conversation
      @params = params
    end

    def list
      guarded do
        { ok: true, directions: directions.order(:created_at).map { |direction| summary(direction) } }
      end
    end

    def add
      guarded do
        direction = directions.new(title: @params["title"], brief: @params["brief"])
        return failure(direction.errors.full_messages.to_sentence) unless direction.save

        { ok: true, action: "added", id: direction.id, title: direction.title }
      end
    end

    def update
      guarded do
        direction = directions.find_by(id: @params["id"].to_i) || raise(Invalid, "No direction with id #{@params["id"].inspect}.")
        direction.view = @params["view"].to_s.strip if @params.key?("view")
        direction.open_questions = Array(@params["open_questions"]).map { |q| q.to_s.strip }.compact_blank.first(10) if @params.key?("open_questions")
        direction.last_explored_at = Time.current
        direction.save!
        { ok: true, action: "updated", id: direction.id }
      end
    end

    def record
      guarded do
        raise Invalid, "This run already recorded #{Hunch::MAX_PER_RUN} hunches." if recorded_this_run >= Hunch::MAX_PER_RUN

        hunch = hunches.new(
          title: @params["title"], body: @params["body"], why_now: @params["why_now"],
          evidence: evidence, conversation: @conversation,
          impact: choice(:impact, Hunch.impacts), confidence: choice(:confidence, Hunch.confidences),
          direction: directions.find_by(id: @params["direction_id"]),
          source_memory: UserMemory.for(@conversation.user, @conversation.team).find_by(id: @params["memory_id"])
        )
        raise Invalid, "A hunch needs at least medium impact." if hunch.impact_low?
        raise Invalid, "A hunch needs evidence: at least one source with a url." if hunch.evidence.empty?
        return failure(hunch.errors.full_messages.to_sentence) unless hunch.save

        { ok: true, action: "recorded", id: hunch.id }
      end
    end

    private

    Invalid = Class.new(StandardError)

    def directions = Direction.for(@conversation.user, @conversation.team)
    def hunches = Hunch.for(@conversation.user, @conversation.team)
    def recorded_this_run = hunches.where(conversation: @conversation).count

    def summary(direction)
      direction.slice(:id, :title, :brief, :status, :view, :open_questions)
               .merge(last_explored_at: direction.last_explored_at&.iso8601)
    end

    def evidence
      Array(@params["evidence"]).filter_map do |source|
        url = source.is_a?(Hash) ? source["url"].to_s.strip : source.to_s.strip
        { "title" => (source["title"].to_s.strip if source.is_a?(Hash)), "url" => url }.compact if url.match?(%r{\Ahttps?://})
      end.first(10)
    end

    def choice(key, options)
      value = @params[key.to_s].to_s.strip.presence || "medium"
      return value if options.key?(value)

      raise Invalid, "#{key.to_s.capitalize} must be one of: #{options.keys.join(", ")}."
    end

    def guarded
      return failure("Directions and hunches aren't available in this conversation.") unless UserMemory.available_in?(@conversation)

      yield
    rescue Invalid => e
      failure(e.message)
    rescue StandardError => e
      Rails.logger.error("ForesightManager failed for conversation #{@conversation.id}: #{e.class}: #{e.message}")
      failure("Something went wrong saving that.")
    end

    def failure(error) = { ok: false, error: error }
  end
end
