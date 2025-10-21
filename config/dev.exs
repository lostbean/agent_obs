import Config

# Development configuration
config :agent_obs,
  enabled: true,
  handlers: []

# Example Phoenix handler configuration for local development
# config :agent_obs, AgentObs.Handlers.Phoenix,
#   endpoint: "http://localhost:6006/v1/traces",
#   api_key: nil  # No auth for local Phoenix
