module Agent
  # Canonical UI event. Backend adapters translate their native event
  # streams into these so the chat UI speaks one vocabulary regardless of
  # which agent is running.
  #
  # `native_ref` carries the original backend event payload — the UI
  # ignores it by default, but backend-aware view helpers can reach into
  # it for native embellishments.
  class UiEvent
    TYPES = %i[
      runtime_status
      message_started
      text_delta
      reasoning_delta
      tool_call_started
      tool_call_progress
      tool_call_finished
      message_finished
      turn_finished
      error
    ].freeze

    # Types that end a prompt's event stream.
    TERMINAL_TYPES = %i[turn_finished].freeze

    attr_reader :type, :data, :native_ref

    def initialize(type, data: {}, native_ref: nil)
      raise ArgumentError, "unknown UiEvent type: #{type.inspect}" unless TYPES.include?(type)

      @type = type
      @data = data.freeze
      @native_ref = native_ref
    end

    def terminal?
      TERMINAL_TYPES.include?(@type)
    end

    def error?
      @type == :error
    end

    def [](key)
      @data[key]
    end

    def to_h
      { type: @type, data: @data, native_ref: @native_ref }
    end

    def inspect
      "#<Agent::UiEvent #{@type} #{@data.inspect}>"
    end
  end
end
