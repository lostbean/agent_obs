import Config

# OpenTelemetry configuration
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
# We'll send traces to both Phoenix and Jaeger using multiple endpoints
# Note: opentelemetry_exporter only supports a single endpoint, so we use Phoenix
# The Generic handler will create basic OTel spans that Phoenix can display
# Note: The exporter automatically appends /v1/traces to the endpoint
config :opentelemetry_exporter,
  otlp_protocol: :http_protobuf,
  otlp_endpoint: System.get_env("ARIZE_PHOENIX_OTLP_ENDPOINT", "http://localhost:6006"),
  otlp_headers: []

# Configure req_llm defaults
config :req_llm,
  default_model: System.get_env("DEFAULT_MODEL", "anthropic:claude-sonnet-4-20250514")
