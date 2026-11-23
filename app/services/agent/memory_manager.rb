module Agent
  # The agent's writes to what it has learned about the operator, over pi's
  # Extension UI channel (Agent::HostBridge). Scoped to the conversation's own
  # user and team, so a turn can only ever touch that user's memories; not
  # admin-gated. Never raises into the turn — a failure is { ok: false }.
  class MemoryManager
    def self.remember(conversation, params) = new(conversation, params).remember
    def self.update(conversation, params) = new(conversation, params).update
    def self.forget(conversation, params) = new(conversation, params).forget
    def self.note_applied(conversation, params) = new(conversation, params).note_applied

    def initialize(conversation, params)
      @conversation = conversation
      @params = params
    end

    def remember
      guarded do
        source = choice(:source, UserMemory.sources, default: "inferred")
        memory = memories.new(
          content: @params["content"],
          kind: choice(:kind, UserMemory.kinds),
          source: source,
          confidence: choice(:confidence, UserMemory.confidences, default: source == "stated" ? "high" : "low"),
          source_conversation: @conversation
        )
        persist(memory, "remembered")
      end
    end

    def update
      guarded do
        memory = find
        memory.content = @params["content"] if @params.key?("content")
        memory.kind = choice(:kind, UserMemory.kinds) if @params.key?("kind")
        memory.confidence = choice(:confidence, UserMemory.confidences) if @params.key?("confidence")
        persist(memory, "updated")
      end
    end

    def forget
      guarded do
        find.destroy!
        { ok: true, action: "forgotten", id: @params["id"].to_i }
      end
    end

    def note_applied
      guarded do
        ids = Array(@params["ids"]).map(&:to_i)
        count = memories.where(id: ids).update_all(last_applied_at: Time.current)
        { ok: true, noted: count }
      end
    end

    private

    Invalid = Class.new(StandardError)

    def memories = UserMemory.for(@conversation.user, @conversation.team)

    def find
      memories.find_by(id: @params["id"].to_i) || raise(Invalid, "No memory with id #{@params["id"].inspect}.")
    end

    def choice(key, options, default: nil)
      value = @params[key.to_s].to_s.strip.presence || default
      return value if options.key?(value)

      raise Invalid, "#{key.to_s.capitalize} must be one of: #{options.keys.join(", ")}."
    end

    def persist(memory, action)
      return failure(memory.errors.full_messages.join("; ")) unless memory.save

      { ok: true, action: action, id: memory.id, kind: memory.kind, source: memory.source,
        confidence: memory.confidence, content: memory.content }
    end

    def guarded
      return failure("Memory isn't available inside a workflow run.") if @conversation.workflow_run.present?

      yield
    rescue Invalid => e
      failure(e.message)
    rescue StandardError => e
      Rails.logger.error("MemoryManager failed for conversation #{@conversation.id}: #{e.class}: #{e.message}")
      failure("Something went wrong saving the memory.")
    end

    def failure(error) = { ok: false, error: error }
  end
end
