# LLM observability — export per-turn token/cost traces to Langfuse (or any
# OTLP backend) over OpenTelemetry. See docs/observability.md.
#
# Off unless METIS_LANGFUSE_ENABLED is truthy AND both keys are present.
# Disabled deployments load none of the OpenTelemetry stack — the gems are
# `require: false` in the Gemfile and only required below when enabled.
#
# Content governance: Message#content/#reasoning are Active Record-encrypted.
# By default only metadata (model, tokens, cost, latency) is exported; set
# METIS_LANGFUSE_INCLUDE_CONTENT=1 to also send prompt/completion text — do
# that only against a self-hosted Langfuse you trust with that data.
module Observability
  def self.truthy?(value)
    %w[1 true yes].include?(value.to_s.strip.downcase)
  end
end

config = Rails.application.config.x.observability

config.langfuse_enabled = Observability.truthy?(ENV["METIS_LANGFUSE_ENABLED"]) &&
                          ENV["LANGFUSE_PUBLIC_KEY"].present? &&
                          ENV["LANGFUSE_SECRET_KEY"].present?
config.langfuse_include_content = Observability.truthy?(ENV["METIS_LANGFUSE_INCLUDE_CONTENT"])

if config.langfuse_enabled
  require "base64"
  require "opentelemetry/sdk"
  require "opentelemetry/exporter/otlp"

  host = (ENV["LANGFUSE_HOST"].presence || "https://cloud.langfuse.com").chomp("/")
  auth = Base64.strict_encode64("#{ENV['LANGFUSE_PUBLIC_KEY']}:#{ENV['LANGFUSE_SECRET_KEY']}")

  OpenTelemetry::SDK.configure do |c|
    c.service_name = "metis"
    c.add_span_processor(
      OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(
        OpenTelemetry::Exporter::OTLP::Exporter.new(
          endpoint: "#{host}/api/public/otel/v1/traces",
          headers: {
            "Authorization" => "Basic #{auth}",
            "x-langfuse-ingestion-version" => "4"
          }
        )
      )
    )
  end

  Rails.logger.info("Langfuse observability enabled → #{host}")
end
