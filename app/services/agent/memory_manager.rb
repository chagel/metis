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
    def self.note_correction(conversation, params) = new(conversation, params).note_correction
    def self.report(conversation, params) = new(conversation, params).report

    def initialize(conversation, params)
      @conversation = conversation
      @params = params
    end

    def remember
      guarded do
        memory = memories.new(content: @params["content"], kind: choice(:kind, UserMemory.kinds))
        assign_provenance(memory)
        persist(memory, "remembered")
      end
    end

    def update
      guarded do
        memory = find
        memory.kind = choice(:kind, UserMemory.kinds) if @params.key?("kind")
        memory.content = @params["content"] if @params.key?("content")
        if memory.content_changed?
          assign_provenance(memory)
        elsif @params.key?("confidence")
          memory.confidence = choice(:confidence, UserMemory.confidences)
        end
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
        ids = memories.where(id: Array(@params["ids"]).map(&:to_i)).pluck(:id)
        memories.where(id: ids).update_all(last_applied_at: Time.current)
        reply = @conversation.inflight_message
        reply&.update_columns(applied_memory_ids: reply.applied_memory_ids | ids)
        { ok: true, noted: ids.size }
      end
    end

    def note_correction
      guarded do
        reply = @conversation.messages.assistant.where.not(streaming_status: %i[pending streaming]).chronological.last
        raise Invalid, "There's no earlier reply in this conversation to mark as corrected." unless reply

        reply.update!(corrected_at: Time.current, correction_note: @params["note"].to_s.strip.truncate(UserMemory::MAX_CONTENT))
        { ok: true, corrected: reply.id }
      end
    end

    def report
      guarded do
        since = MemoryReview.window_start(@conversation.user, @conversation.team, before: @conversation.created_at)
        { ok: true, **Agent::MemoryReport.new(@conversation.user, @conversation.team, since: since).to_h }
      end
    end

    private

    Invalid = Class.new(StandardError)

    def memories = UserMemory.for(@conversation.user, @conversation.team)

    # New wording is a new claim, so it never inherits an earlier "stated".
    def assign_provenance(memory)
      memory.source = choice(:source, UserMemory.sources, default: "inferred")
      memory.confidence = choice(:confidence, UserMemory.confidences, default: memory.source_stated? ? "high" : "low")
      memory.source_conversation = @conversation
    end

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

      { ok: true, action: action, id: memory.id, kind: memory.kind, source: memory.source, confidence: memory.confidence }
    end

    def guarded
      return failure("Memory isn't available in this conversation.") unless UserMemory.available_in?(@conversation)

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
