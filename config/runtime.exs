import Config

# Runtime configuration for production
if config_env() == :prod do
  # OpenTelemetry SDK configuration
  config :opentelemetry,
    span_processor: :batch,
    resource: [
      service: [
        name: System.get_env("OTEL_SERVICE_NAME", "agent_obs_app")
      ]
    ]

  # OTLP Exporter configuration
  config :opentelemetry_exporter,
    otlp_protocol: :http_protobuf,
    otlp_endpoint: System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT"),
    otlp_headers: [
      {"authorization", "Bearer #{System.get_env("OTEL_EXPORTER_OTLP_HEADERS")}"}
    ]

  # Example: Arize Phoenix configuration
  # config :agent_obs, AgentObs.Handlers.Phoenix,
  #   endpoint: System.fetch_env!("ARIZE_PHOENIX_OTLP_ENDPOINT"),
  #   api_key: System.fetch_env!("ARIZE_PHOENIX_API_KEY")
end
