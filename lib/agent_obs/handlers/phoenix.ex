defmodule AgentObs.Handlers.Phoenix do
  @moduledoc """
  Arize Phoenix handler for AgentObs.

  This handler translates AgentObs telemetry events into OpenTelemetry spans
  with OpenInference semantic conventions, suitable for export to Arize Phoenix
  or any OpenInference-compatible observability platform.

  ## Configuration

      config :agent_obs,
        handlers: [AgentObs.Handlers.Phoenix]

      config :agent_obs, AgentObs.Handlers.Phoenix,
        endpoint: "http://localhost:6006/v1/traces",
        api_key: nil  # Optional, for authenticated Phoenix instances

  ## OpenTelemetry SDK Configuration

  This handler requires the OpenTelemetry SDK to be configured in your application.
  Add to `config/runtime.exs`:

      config :opentelemetry,
        span_processor: :batch,
        resource: [service: [name: "my_llm_agent"]]

      config :opentelemetry_exporter,
        otlp_protocol: :http_protobuf,
        otlp_endpoint: System.fetch_env!("ARIZE_PHOENIX_OTLP_ENDPOINT"),
        otlp_headers: [
          {"authorization", "Bearer \#{System.get_env("ARIZE_PHOENIX_API_KEY")}"}
        ]

  ## How It Works

  1. Attaches to all AgentObs telemetry events (:agent, :tool, :llm, :prompt)
  2. On :start events, creates an OpenTelemetry span and stores context in process dictionary
  3. On :stop events, adds attributes and ends the span
  4. On :exception events, records the exception and marks span as errored
  5. Uses Phoenix.Translator to convert metadata to OpenInference attributes

  ## Span Context Management

  Spans are stored in the process dictionary with a unique key per event type.
  This allows nested instrumentation (e.g., agent -> llm -> tool) to create
  proper parent-child span relationships automatically.
  """

  use GenServer
  @behaviour AgentObs.Handler

  require OpenTelemetry.Tracer, as: Tracer
  require Logger

  alias AgentObs.Handlers.Phoenix.Translator

  # Client API

  @doc """
  Starts the Phoenix handler GenServer.

  Called by AgentObs.Supervisor with handler-specific configuration.
  """
  @spec start_link(map()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # AgentObs.Handler callbacks

  @impl AgentObs.Handler
  def attach(config) do
    event_prefix = Map.get(config, :event_prefix, [:agent_obs])
    handler_id = {:agent_obs_phoenix, event_prefix, self()}

    events_to_attach = [
      event_prefix ++ [:agent, :start],
      event_prefix ++ [:agent, :stop],
      event_prefix ++ [:agent, :exception],
      event_prefix ++ [:tool, :start],
      event_prefix ++ [:tool, :stop],
      event_prefix ++ [:tool, :exception],
      event_prefix ++ [:llm, :start],
      event_prefix ++ [:llm, :stop],
      event_prefix ++ [:llm, :exception],
      event_prefix ++ [:prompt, :start],
      event_prefix ++ [:prompt, :stop],
      event_prefix ++ [:prompt, :exception]
    ]

    :ok =
      :telemetry.attach_many(
        handler_id,
        events_to_attach,
        &__MODULE__.handle_event/4,
        config
      )

    Logger.debug(
      "AgentObs.Handlers.Phoenix: Attached to events with prefix #{inspect(event_prefix)}"
    )

    {:ok, %{handler_id: handler_id, config: config}}
  end

  @impl AgentObs.Handler
  def handle_event(event_name, measurements, metadata, _config) do
    event_type = get_event_type(event_name)
    phase = get_event_phase(event_name)

    case phase do
      :start -> handle_start(event_type, metadata)
      :stop -> handle_stop(event_type, measurements, metadata)
      :exception -> handle_exception(event_type, measurements, metadata)
    end

    :ok
  rescue
    exception ->
      Logger.error(
        "AgentObs.Handlers.Phoenix: Error handling event #{inspect(event_name)}: #{inspect(exception)}"
      )

      :ok
  end

  @impl AgentObs.Handler
  def detach(state) do
    :telemetry.detach(state.handler_id)
    Logger.debug("AgentObs.Handlers.Phoenix: Detached from telemetry events")
    :ok
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

  # Private event handling functions

  defp handle_start(event_type, metadata) do
    attributes = Translator.from_start_metadata(event_type, metadata)
    span_name = Map.get(metadata, :name, "#{event_type}_operation")

    span_ctx = Tracer.start_span(span_name, %{attributes: attributes})

    # Store span context in process dictionary with event-type-specific key
    # This allows nested spans to work correctly
    span_key = span_context_key(event_type)
    Process.put(span_key, span_ctx)

    :ok
  end

  defp handle_stop(event_type, measurements, metadata) do
    span_key = span_context_key(event_type)

    with span_ctx when not is_nil(span_ctx) <- Process.get(span_key) do
      attributes = Translator.from_stop_metadata(event_type, metadata, measurements)

      Tracer.set_attributes(attributes)
      Tracer.end_span()

      Process.delete(span_key)
    else
      nil ->
        Logger.warning(
          "AgentObs.Handlers.Phoenix: No active span found for #{event_type} :stop event"
        )
    end

    :ok
  end

  defp handle_exception(event_type, measurements, metadata) do
    span_key = span_context_key(event_type)

    with span_ctx when not is_nil(span_ctx) <- Process.get(span_key) do
      attributes = Translator.from_exception_metadata(event_type, metadata, measurements)

      Tracer.set_attributes(attributes)

      # Record the exception details
      kind = metadata[:kind] || :error
      reason = metadata[:reason] || "Unknown error"
      stacktrace = metadata[:stacktrace] || []

      Tracer.record_exception(kind, reason, stacktrace)
      Tracer.set_status(OpenTelemetry.status(:error, "Exception occurred"))
      Tracer.end_span()

      Process.delete(span_key)
    else
      nil ->
        Logger.warning(
          "AgentObs.Handlers.Phoenix: No active span found for #{event_type} :exception event"
        )
    end

    :ok
  end

  # Private utility functions

  defp get_event_type(event_name) do
    # Event name format: [:agent_obs, :llm, :start]
    # Extract :llm
    event_name
    |> Enum.reverse()
    |> Enum.drop(1)
    |> List.first()
  end

  defp get_event_phase(event_name) do
    # Event name format: [:agent_obs, :llm, :start]
    # Extract :start
    List.last(event_name)
  end

  defp span_context_key(event_type) do
    :"agent_obs_span_#{event_type}"
  end
end
