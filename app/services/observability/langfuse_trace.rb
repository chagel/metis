module Observability
  # Emits one OpenTelemetry trace per finished agent turn, shaped for
  # Langfuse: a root "agent" span carrying the session/user grouping, a
  # child "generation" span carrying the turn's tokens + cost, and a child
  # "tool" span per tool call. Attribute names follow the gen_ai.* and
  # langfuse.observation.type conventions Langfuse ingests.
  #
  # All numbers come straight off the persisted assistant Message (pi prices
  # the turn itself — see Agent::Adapters::Pi#cost_total), so this never
  # talks to pi. It runs from ChatJob after the turn is saved and must never
  # raise into the turn: ::record_turn rescues and logs.
  #
  # Content (prompt/completion, tool args/output) is exported only when
  # config.x.observability.langfuse_include_content is set, because
  # Message#content is encrypted at rest.
  class LangfuseTrace
    TRACER_NAME = "metis"

    def self.config = Rails.application.config.x.observability

    def self.record_turn(conversation:, user_message:, assistant_message:)
      return unless config.langfuse_enabled

      new(conversation, user_message, assistant_message).emit
    rescue StandardError => e
      Rails.logger.warn("Langfuse trace failed for message #{assistant_message&.id}: #{e.class}: #{e.message}")
    end

    def initialize(conversation, user_message, assistant_message)
      @conversation = conversation
      @user_message = user_message
      @message = assistant_message
    end

    def emit
      tracer = OpenTelemetry.tracer_provider.tracer(TRACER_NAME)
      started = @message.started_at
      finished = @message.finished_at

      root = tracer.start_span("metis.turn", attributes: root_attributes, start_timestamp: started)
      context = OpenTelemetry::Trace.context_with_span(root)

      generation = tracer.start_span("metis.generation",
        with_parent: context, attributes: generation_attributes, start_timestamp: started)
      generation.finish(end_timestamp: finished)

      tool_calls.each do |call|
        span = tracer.start_span("metis.tool.#{call['name']}",
          with_parent: context, attributes: tool_attributes(call), start_timestamp: started)
        span.status = OpenTelemetry::Trace::Status.error("tool error") if call["is_error"]
        span.finish(end_timestamp: finished)
      end

      root.finish(end_timestamp: finished)
    end

    # --- attribute builders (pure; no OTel calls) ---

    def root_attributes
      {
        "langfuse.observation.type" => "agent",
        "gen_ai.system" => provider,
        "gen_ai.request.model" => model,
        "session.id" => @conversation.id.to_s,
        "user.id" => @conversation.user_id.to_s,
        "langfuse.metadata.team_id" => @conversation.team_id.to_s,
        "langfuse.metadata.runtime" => @conversation.runtime_label,
        "input.value" => content(@user_message&.content),
        "output.value" => content(@message.content)
      }.compact
    end

    def generation_attributes
      {
        "langfuse.observation.type" => "generation",
        "gen_ai.request.model" => model,
        "gen_ai.usage.input_tokens" => @message.input_tokens,
        "gen_ai.usage.output_tokens" => @message.output_tokens,
        "gen_ai.usage.cache_read_input_tokens" => @message.cache_read_tokens,
        "gen_ai.usage.cost" => cost,
        "output.value" => content(@message.content)
      }.compact
    end

    def tool_attributes(call)
      {
        "langfuse.observation.type" => "tool",
        "tool.name" => call["name"],
        "input.value" => content(call["args"].is_a?(String) ? call["args"] : call["args"]&.to_json),
        "output.value" => content(call["output"])
      }.compact
    end

    private

    def model = @message.model_key.presence || @conversation.model_label

    def provider = @conversation.agent_model&.dig("provider")

    def cost = @message.cost&.to_f

    def tool_calls = @message.tool_calls || []

    # Honour the content-export toggle: metadata-only by default because
    # Message#content is encrypted at rest.
    def content(value)
      return nil unless self.class.config.langfuse_include_content

      value.presence
    end
  end
end
