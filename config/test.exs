import Config

# Test configuration - disable automatic handler startup
config :agent_obs,
  enabled: false,
  handlers: []

# Configure OpenTelemetry for testing
if endpoint = System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") do
  # When an OTLP endpoint is set, use the batch processor so spans are
  # exported to the collector (e.g. Arize Phoenix on localhost:6060).
  # The simple processor + :otel_exporter_pid is still used per-test via
  # set_exporter in the test setup block, so unit tests keep working.
  config :opentelemetry,
    resource: [service: [name: "agent_obs_test"]],
    span_processor: :batch,
    traces_exporter: :otlp

  config :opentelemetry_exporter,
    otlp_protocol: :http_protobuf,
    otlp_endpoint: endpoint
else
  config :opentelemetry,
    resource: [service: [name: "agent_obs_test"]],
    span_processor: :simple
end

# Set log level to warning to reduce test output noise
config :logger, level: :warning
