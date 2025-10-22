import Config

# OpenTelemetry configuration
# We configure the SDK to send traces to the primary backend (Phoenix)
# For dual-backend support, we would need an OpenTelemetry Collector
# or custom exporter configuration, which is beyond the scope of basic setup.
#
# Instead, we'll use environment variable to switch between backends:
# - OTLP_BACKEND=phoenix (default) -> http://localhost:6006
# - OTLP_BACKEND=jaeger -> http://localhost:4318

backend = System.get_env("OTLP_BACKEND", "phoenix")

otlp_endpoint =
  case backend do
    "jaeger" -> System.get_env("JAEGER_OTLP_ENDPOINT", "http://localhost:4318")
    _ -> System.get_env("ARIZE_PHOENIX_OTLP_ENDPOINT", "http://localhost:6006")
  end

config :opentelemetry,
  span_processor: :batch,
  traces_exporter: :otlp,
  resource: [
    service: [
      name: System.get_env("OTEL_SERVICE_NAME", "agent_obs_demo"),
      version: "0.1.0"
    ]
  ]

# OTLP Exporter configuration
# The exporter automatically appends /v1/traces to the endpoint for HTTP
config :opentelemetry_exporter,
  otlp_protocol: :http_protobuf,
  otlp_endpoint: otlp_endpoint,
  otlp_headers: []

# Configure req_llm defaults
config :req_llm,
  default_model: System.get_env("DEFAULT_MODEL", "anthropic:claude-sonnet-4-20250514")
