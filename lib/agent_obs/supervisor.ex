defmodule AgentObs.Supervisor do
  @moduledoc """
  Supervisor for AgentObs handler processes.

  Starts and supervises configured handler GenServers based on application
  configuration. Uses a `:one_for_one` strategy to ensure that if a handler
  crashes, it is restarted without affecting other handlers.

  ## Configuration

  Handlers are configured in application config:

      config :agent_obs,
        handlers: [AgentObs.Handlers.Phoenix, AgentObs.Handlers.Generic]

      config :agent_obs, AgentObs.Handlers.Phoenix,
        endpoint: "http://localhost:6006/v1/traces"

  Each handler module in the `:handlers` list will be started as a child process,
  with its configuration read from the application environment.
  """

  use Supervisor

  require Logger

  @doc """
  Starts the AgentObs supervisor.

  Called by AgentObs.Application during startup.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    enabled = Application.get_env(:agent_obs, :enabled, true)
    handlers = Application.get_env(:agent_obs, :handlers, [])

    children =
      if enabled do
        Logger.debug("AgentObs: Initializing with handlers: #{inspect(handlers)}")

        Enum.map(handlers, fn handler_module ->
          config = get_handler_config(handler_module)

          {handler_module, config}
        end)
      else
        Logger.debug("AgentObs: Disabled, no handlers will be started")
        []
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Retrieves configuration for a specific handler module.

  Reads from application environment under the handler's module name,
  and adds common configuration like event_prefix.
  """
  @spec get_handler_config(module()) :: map()
  def get_handler_config(handler_module) do
    handler_config = Application.get_env(:agent_obs, handler_module, %{})
    event_prefix = Application.get_env(:agent_obs, :event_prefix, [:agent_obs])

    handler_config
    |> Map.new()
    |> Map.put_new(:event_prefix, event_prefix)
  end
end
