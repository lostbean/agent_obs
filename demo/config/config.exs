import Config

# Configure AgentObs handlers based on OTLP_BACKEND environment variable
# - OTLP_BACKEND=phoenix (default) -> Uses Phoenix handler with OpenInference
# - OTLP_BACKEND=jaeger -> Uses Generic handler for standard OTel
# - OTLP_BACKEND=both -> Uses both handlers (dual instrumentation)
backend = System.get_env("OTLP_BACKEND", "phoenix")

handlers =
  case backend do
    "jaeger" -> [AgentObs.Handlers.Generic]
    "both" -> [AgentObs.Handlers.Phoenix, AgentObs.Handlers.Generic]
    _ -> [AgentObs.Handlers.Phoenix]
  end

config :agent_obs,
  enabled: true,
  handlers: handlers,
  event_prefix: [:demo]

# Configure logger
config :logger,
  level: :info,
  format: "$time $metadata[$level] $message\n"

# Import environment specific config
import_config "#{config_env()}.exs"
