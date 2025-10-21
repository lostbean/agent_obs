import Config

# Test configuration - disable automatic handler startup
config :agent_obs,
  enabled: false,
  handlers: []

# Configure OpenTelemetry for testing
config :opentelemetry,
  resource: [service: [name: "agent_obs_test"]],
  span_processor: :simple

config :opentelemetry_exporter,
  otlp_protocol: :http_protobuf,
  otlp_endpoint: "http://localhost:4318"
