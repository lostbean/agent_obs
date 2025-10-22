import Config

# Configure AgentObs with dual backends
config :agent_obs,
  enabled: true,
  handlers: [
    # OpenInference for Arize Phoenix
    AgentObs.Handlers.Phoenix
    # Generic OTel for Jaeger - temporarily disabled to test Phoenix handler
    # AgentObs.Handlers.Generic
  ],
  event_prefix: [:demo]

# Configure logger
config :logger,
  level: :info,
  format: "$time $metadata[$level] $message\n"

# Import environment specific config
import_config "#{config_env()}.exs"
