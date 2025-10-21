defmodule AgentObs.Application do
  @moduledoc """
  OTP Application for AgentObs.

  Starts the AgentObs supervisor which manages configured handler processes.
  The application can be disabled by setting `enabled: false` in configuration.

  ## Configuration

      config :agent_obs,
        enabled: true,
        handlers: [AgentObs.Handlers.Phoenix]
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    enabled = Application.get_env(:agent_obs, :enabled, true)

    children =
      if enabled do
        Logger.info("AgentObs: Starting application")
        [AgentObs.Supervisor]
      else
        Logger.info("AgentObs: Application disabled via configuration")
        []
      end

    opts = [strategy: :one_for_one, name: AgentObs.ApplicationSupervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def stop(_state) do
    Logger.debug("AgentObs: Stopping application")
    :ok
  end
end
