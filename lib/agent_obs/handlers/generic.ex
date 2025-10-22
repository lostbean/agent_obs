defmodule AgentObs.Handlers.Generic do
  @moduledoc """
  Generic OpenTelemetry handler for AgentObs.

  This handler creates basic OpenTelemetry spans without OpenInference semantic
  conventions. Use this handler for generic OTel backends that don't support
  OpenInference (e.g., Jaeger, Zipkin, generic APM tools).

  ## Configuration

      config :agent_obs,
        handlers: [AgentObs.Handlers.Generic]

      config :agent_obs, AgentObs.Handlers.Generic,
        endpoint: "http://localhost:4318"

  ## Differences from Phoenix Handler

  - Does not use OpenInference semantic conventions
  - Simpler attribute structure (no message flattening)
  - Uses standard OTel span kinds (INTERNAL, CLIENT, etc.)
  - Suitable for general-purpose observability platforms

  ## OpenTelemetry SDK Configuration

      config :opentelemetry,
        span_processor: :batch,
        resource: [service: [name: "my_app"]]

      config :opentelemetry_exporter,
        otlp_protocol: :http_protobuf,
        otlp_endpoint: System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT")
  """

  use GenServer
  @behaviour AgentObs.Handler

  require OpenTelemetry.Tracer, as: Tracer
  require Logger

  # Client API

  @doc """
  Starts the Generic handler GenServer.
  """
  @spec start_link(map()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # AgentObs.Handler callbacks

  @impl AgentObs.Handler
  def attach(config) do
    event_prefix = Map.get(config, :event_prefix, [:agent_obs])
    handler_id = {:agent_obs_generic, event_prefix, self()}

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
      "AgentObs.Handlers.Generic: Attached to events with prefix #{inspect(event_prefix)}"
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
        "AgentObs.Handlers.Generic: Error handling event #{inspect(event_name)}: #{inspect(exception)}"
      )

      :ok
  end

  @impl AgentObs.Handler
  def detach(state) do
    :telemetry.detach(state.handler_id)
    Logger.debug("AgentObs.Handlers.Generic: Detached from telemetry events")
    :ok
  end

  # GenServer callbacks

  @impl GenServer
  def init(opts) do
    {:ok, state} = attach(opts)
    {:ok, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    detach(state)
  end

  # Private event handling functions

  defp handle_start(event_type, metadata) do
    attributes = build_start_attributes(event_type, metadata)
    span_name = Map.get(metadata, :name, "#{event_type}_operation")

    span_ctx = Tracer.start_span(span_name, %{attributes: attributes})

    # IMPORTANT: Set as current span so OpenTelemetry SDK tracks and exports it
    Tracer.set_current_span(span_ctx)

    span_key = span_context_key(event_type)
    Process.put(span_key, span_ctx)

    :ok
  end

  defp handle_stop(event_type, measurements, metadata) do
    span_key = span_context_key(event_type)

    case Process.get(span_key) do
      span_ctx when not is_nil(span_ctx) ->
        attributes = build_stop_attributes(event_type, metadata, measurements)

        Tracer.set_attributes(attributes)
        Tracer.end_span()

        Process.delete(span_key)

      nil ->
        Logger.warning(
          "AgentObs.Handlers.Generic: No active span found for #{event_type} :stop event"
        )
    end

    :ok
  end

  defp handle_exception(event_type, _measurements, metadata) do
    span_key = span_context_key(event_type)

    case Process.get(span_key) do
      span_ctx when not is_nil(span_ctx) ->
        kind = metadata[:kind] || :error
        reason = metadata[:reason] || "Unknown error"
        stacktrace = metadata[:stacktrace] || []

        Tracer.record_exception(kind, reason, stacktrace)
        Tracer.set_status(OpenTelemetry.status(:error, "Exception occurred"))
        Tracer.end_span()

        Process.delete(span_key)

      nil ->
        Logger.warning(
          "AgentObs.Handlers.Generic: No active span found for #{event_type} :exception event"
        )
    end

    :ok
  end

  # Attribute building functions - simplified compared to Phoenix handler

  defp build_start_attributes(:agent, metadata) do
    %{
      "agent.name" => metadata.name,
      "input.value" => to_string_safe(metadata.input)
    }
    |> maybe_add("model", metadata[:model])
  end

  defp build_start_attributes(:tool, metadata) do
    %{
      "tool.name" => metadata.name,
      "tool.arguments" => encode_json(metadata.arguments)
    }
    |> maybe_add("tool.description", metadata[:description])
  end

  defp build_start_attributes(:llm, metadata) do
    %{
      "llm.model" => metadata.model,
      "llm.request" => encode_json(metadata)
    }
  end

  defp build_start_attributes(:prompt, metadata) do
    %{
      "prompt.name" => metadata.name,
      "prompt.variables" => encode_json(metadata.variables)
    }
  end

  defp build_stop_attributes(:agent, metadata, measurements) do
    %{
      "output.value" => to_string_safe(metadata[:output])
    }
    |> maybe_add("agent.iterations", metadata[:iterations])
    |> add_duration(measurements)
  end

  defp build_stop_attributes(:tool, metadata, measurements) do
    %{
      "output.value" => to_string_safe(metadata[:result])
    }
    |> add_duration(measurements)
  end

  defp build_stop_attributes(:llm, metadata, measurements) do
    %{}
    |> maybe_add("llm.token_count", get_in(metadata, [:tokens, :total]))
    |> maybe_add("llm.cost", metadata[:cost])
    |> add_duration(measurements)
  end

  defp build_stop_attributes(:prompt, metadata, measurements) do
    %{
      "output.value" => to_string_safe(metadata[:rendered])
    }
    |> add_duration(measurements)
  end

  # Private utility functions

  defp get_event_type(event_name) do
    event_name
    |> Enum.reverse()
    |> Enum.drop(1)
    |> List.first()
  end

  defp get_event_phase(event_name) do
    List.last(event_name)
  end

  defp span_context_key(event_type) do
    :"agent_obs_generic_span_#{event_type}"
  end

  defp maybe_add(attrs, _key, nil), do: attrs
  defp maybe_add(attrs, key, value), do: Map.put(attrs, key, value)

  defp add_duration(attrs, measurements) do
    case Map.get(measurements, :duration) do
      nil ->
        attrs

      duration when is_integer(duration) ->
        duration_ms = duration / 1_000_000
        Map.put(attrs, "duration_ms", duration_ms)

      _ ->
        attrs
    end
  end

  defp to_string_safe(value) when is_binary(value), do: value
  defp to_string_safe(value) when is_atom(value), do: to_string(value)
  defp to_string_safe(value), do: encode_json(value)

  defp encode_json(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _} -> inspect(value)
    end
  end
end
