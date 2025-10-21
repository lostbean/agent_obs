defmodule AgentObs.Handler do
  @moduledoc """
  Behaviour for AgentObs backend handlers.

  Handlers receive telemetry events emitted by AgentObs instrumentation
  and translate them to backend-specific formats (OpenTelemetry spans,
  logs, metrics, etc.).

  ## Implementing a Handler

  To create a custom handler, implement this behaviour in a GenServer:

      defmodule MyApp.CustomHandler do
        use GenServer
        @behaviour AgentObs.Handler

        def start_link(opts) do
          GenServer.start_link(__MODULE__, opts, name: __MODULE__)
        end

        @impl AgentObs.Handler
        def attach(config) do
          event_prefix = Map.get(config, :event_prefix, [:agent_obs])
          handler_id = {:my_custom_handler, event_prefix, self()}

          events_to_attach = [
            event_prefix ++ [:agent, :start],
            event_prefix ++ [:agent, :stop],
            # ... more events
          ]

          :ok = :telemetry.attach_many(
            handler_id,
            events_to_attach,
            &__MODULE__.handle_event/4,
            config
          )

          {:ok, %{handler_id: handler_id, config: config}}
        end

        @impl AgentObs.Handler
        def handle_event(event_name, measurements, metadata, config) do
          # Process the event
          IO.inspect({event_name, measurements, metadata})
          :ok
        end

        @impl AgentObs.Handler
        def detach(state) do
          :telemetry.detach(state.handler_id)
        end

        # GenServer callbacks
        @impl GenServer
        def init(opts) do
          case attach(opts) do
            {:ok, state} -> {:ok, state}
            {:error, reason} -> {:stop, reason}
          end
        end

        @impl GenServer
        def terminate(_reason, state) do
          detach(state)
        end
      end

  ## Configuration

  Handlers are configured in the application config:

      config :agent_obs,
        handlers: [MyApp.CustomHandler]

      config :agent_obs, MyApp.CustomHandler,
        custom_option: "value"

  The handler will receive this configuration in the `attach/1` callback.

  ## Synchronous Execution

  Handler callbacks are executed synchronously when telemetry events are emitted.
  Keep processing fast to avoid blocking the application. For expensive operations,
  consider sending work to a separate process or using asynchronous export.
  """

  @doc """
  Attaches the handler to telemetry events.

  Called during handler initialization. Should use `:telemetry.attach_many/4`
  to register for relevant events.

  Returns `{:ok, state}` or `{:error, reason}`.

  ## Parameters

  - `config` - Configuration map for the handler, typically read from application config

  ## Examples

      def attach(config) do
        event_prefix = Map.get(config, :event_prefix, [:agent_obs])
        handler_id = {:my_handler, event_prefix, self()}

        :ok = :telemetry.attach_many(
          handler_id,
          [event_prefix ++ [:agent, :start]],
          &__MODULE__.handle_event/4,
          config
        )

        {:ok, %{handler_id: handler_id}}
      end
  """
  @callback attach(config :: map()) :: {:ok, term()} | {:error, term()}

  @doc """
  Handles a telemetry event.

  Called synchronously when an attached event is emitted. Should process
  the event quickly to avoid blocking the emitting process.

  ## Parameters

  - `event_name` - The full event name as a list of atoms (e.g., `[:agent_obs, :llm, :start]`)
  - `measurements` - Map of measurements (e.g., `%{duration: 1000000}` for :stop events)
  - `metadata` - Event-specific metadata according to AgentObs.Events schema
  - `config` - The handler configuration passed during attachment

  ## Examples

      def handle_event([:agent_obs, :llm, :start], _measurements, metadata, _config) do
        IO.inspect(metadata.model)
        :ok
      end
  """
  @callback handle_event(
              event_name :: [atom()],
              measurements :: map(),
              metadata :: map(),
              config :: term()
            ) :: :ok

  @doc """
  Detaches the handler from telemetry events.

  Called during handler termination. Should clean up any resources
  and detach from telemetry events.

  ## Parameters

  - `state` - The handler's internal state

  ## Examples

      def detach(state) do
        :telemetry.detach(state.handler_id)
      end
  """
  @callback detach(state :: term()) :: :ok
end
