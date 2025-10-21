import Config

# Configure AgentObs defaults
config :agent_obs,
  enabled: true,
  handlers: [],
  event_prefix: [:agent_obs]

# Import environment specific config
import_config "#{config_env()}.exs"
