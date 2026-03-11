defmodule AgentObs.JidoTracer do
  @moduledoc """
  A `Jido.Observe.Tracer` implementation that bridges Jido composer events to
  AgentObs OpenTelemetry spans with OpenInference semantic conventions.

  This module translates Jido's event prefixes and metadata into the AgentObs
  format expected by `AgentObs.Handlers.Phoenix.Translator`, then creates and
  manages OpenTelemetry spans with proper parent-child nesting.

  ## Setup

  Add `jido` to your deps (it's an optional dependency of `agent_obs`):

      {:jido, "~> 2.0"}

  Then point Jido at this tracer:

      # config/config.exs
      config :jido, :observability,
        tracer: AgentObs.JidoTracer

  No other changes are needed — all composer events are automatically traced.

  ## Event Prefix Mapping

  | Jido prefix | AgentObs type |
  |---|---|
  | `[:jido, :composer, :agent, ...]` | `:agent` |
  | `[:jido, :composer, :llm, ...]` | `:llm` |
  | `[:jido, :composer, :tool, ...]` | `:tool` |
  | `[:jido, :composer, :iteration, ...]` | `:chain` |
  | anything else | `:agent` (fallback) |

  ## Metadata Translation

  Jido metadata fields are mapped to AgentObs conventions:

  - **Agent events:** `:query` / `:input` → `:input`, `:name` / `:agent_module` → `:name`
  - **LLM events:** `:model`, `:conversation` → normalized `:input_messages`, `:iteration`
  - **Tool events:** `:tool_name` / `:node_name` → `:name`, `:arguments` / `:params`

  ## Error Handling

  All callbacks are wrapped in `rescue` blocks. If span creation or attribute
  translation fails, a warning is logged and execution continues — the tracer
  will never crash your application.

  ## See Also

  - [Jido Integration Guide](guides/jido_integration.md) for full documentation
  - `AgentObs.Handlers.Phoenix.Translator` for attribute generation details
  """

  @behaviour Jido.Observe.Tracer

  require OpenTelemetry.Tracer, as: Tracer
  require Logger

  alias AgentObs.Handlers.Phoenix.Translator

  @type tracer_ctx :: %{
          otel_span_ctx: term(),
          parent_ctx: term(),
          event_type: :agent | :llm | :tool | :chain
        }

  @impl Jido.Observe.Tracer
  @spec span_start([atom()], map()) :: tracer_ctx()
  def span_start(event_prefix, metadata) do
    event_type = classify_event_type(event_prefix)
    translated = translate_start_metadata(event_type, metadata)
    span_name = build_span_name(event_type, metadata, event_prefix)

    attributes = Translator.from_start_metadata(event_type, translated)

    parent_ctx = OpenTelemetry.Ctx.get_current()
    span_ctx = Tracer.start_span(span_name, %{attributes: attributes})
    new_ctx = OpenTelemetry.Tracer.set_current_span(parent_ctx, span_ctx)
    OpenTelemetry.Ctx.attach(new_ctx)

    %{
      otel_span_ctx: span_ctx,
      parent_ctx: parent_ctx,
      event_type: event_type
    }
  rescue
    e ->
      Logger.warning("AgentObs.JidoTracer span_start failed: #{inspect(e)}")
      %{otel_span_ctx: nil, parent_ctx: nil, event_type: classify_event_type(event_prefix)}
  end

  @impl Jido.Observe.Tracer
  @spec span_stop(term(), map()) :: :ok
  def span_stop(nil, _measurements), do: :ok

  def span_stop(%{otel_span_ctx: nil}, _measurements), do: :ok

  def span_stop(
        %{otel_span_ctx: span_ctx, parent_ctx: parent_ctx, event_type: event_type},
        measurements
      ) do
    translated = translate_stop_metadata(event_type, measurements)
    attributes = Translator.from_stop_metadata(event_type, translated, measurements)

    OpenTelemetry.Span.set_attributes(span_ctx, attributes)

    if Map.has_key?(measurements, :error) do
      error_msg = inspect(measurements[:error])
      OpenTelemetry.Span.set_status(span_ctx, OpenTelemetry.status(:error, error_msg))
    else
      OpenTelemetry.Span.set_status(span_ctx, OpenTelemetry.status(:ok))
    end

    OpenTelemetry.Span.end_span(span_ctx)
    OpenTelemetry.Ctx.attach(parent_ctx)

    :ok
  rescue
    e ->
      Logger.warning("AgentObs.JidoTracer span_stop failed: #{inspect(e)}")
      :ok
  end

  @impl Jido.Observe.Tracer
  @spec span_exception(term(), atom(), term(), list()) :: :ok
  def span_exception(nil, _kind, _reason, _stacktrace), do: :ok

  def span_exception(%{otel_span_ctx: nil}, _kind, _reason, _stacktrace), do: :ok

  def span_exception(
        %{otel_span_ctx: span_ctx, parent_ctx: parent_ctx, event_type: event_type},
        kind,
        reason,
        stacktrace
      ) do
    exception_metadata = %{kind: kind, reason: reason, stacktrace: stacktrace}
    attributes = Translator.from_exception_metadata(event_type, exception_metadata, %{})

    OpenTelemetry.Span.set_attributes(span_ctx, attributes)

    if is_exception(reason) do
      OpenTelemetry.Span.record_exception(span_ctx, reason, stacktrace)
    end

    error_message = format_exception_message(kind, reason)
    OpenTelemetry.Span.set_status(span_ctx, OpenTelemetry.status(:error, error_message))

    OpenTelemetry.Span.end_span(span_ctx)
    OpenTelemetry.Ctx.attach(parent_ctx)

    :ok
  rescue
    e ->
      Logger.warning("AgentObs.JidoTracer span_exception failed: #{inspect(e)}")
      :ok
  end

  # -- Event type classification --

  defp classify_event_type([:jido, :composer, :agent | _]), do: :agent
  defp classify_event_type([:jido, :composer, :llm | _]), do: :llm
  defp classify_event_type([:jido, :composer, :tool | _]), do: :tool
  defp classify_event_type([:jido, :composer, :iteration | _]), do: :chain
  defp classify_event_type(_), do: :agent

  # -- Metadata translation (Jido → AgentObs format) --

  defp translate_start_metadata(:agent, metadata) do
    %{
      input: metadata[:query] || metadata[:input] || "",
      name: metadata[:name] || metadata[:agent_module] || "agent"
    }
    |> maybe_put(:model, metadata[:model])
  end

  defp translate_start_metadata(:llm, metadata) do
    base =
      %{
        model: metadata[:model] || "unknown"
      }
      |> maybe_put(:iteration, metadata[:iteration])

    # Prefer input_messages, fall back to extracting from conversation
    messages =
      cond do
        metadata[:input_messages] ->
          metadata[:input_messages]

        metadata[:conversation] ->
          normalize_messages(metadata[:conversation])

        true ->
          nil
      end

    if messages, do: Map.put(base, :input_messages, messages), else: base
  end

  defp translate_start_metadata(:tool, metadata) do
    %{
      name: metadata[:tool_name] || metadata[:node_name] || metadata[:name] || "tool",
      arguments: metadata[:arguments] || metadata[:params]
    }
  end

  defp translate_start_metadata(:chain, metadata) do
    %{iteration: metadata[:iteration] || 1}
    |> maybe_put(:input, metadata[:input])
  end

  defp translate_stop_metadata(:agent, measurements) do
    %{}
    |> maybe_put(:output, measurements[:result] || measurements[:output])
    |> maybe_put(:iterations, measurements[:iterations])
    |> maybe_put(:tokens, measurements[:tokens])
  end

  defp translate_stop_metadata(:llm, measurements) do
    %{}
    |> maybe_put(:tokens, measurements[:tokens])
    |> maybe_put(:output_messages, measurements[:output_messages])
    |> maybe_put(:finish_reason, measurements[:finish_reason])
  end

  defp translate_stop_metadata(:tool, measurements) do
    %{
      result: measurements[:result] || measurements[:output]
    }
  end

  defp translate_stop_metadata(:chain, measurements) do
    %{}
    |> maybe_put(:output, measurements[:output] || measurements[:result])
  end

  # -- Span name building --

  defp build_span_name(:agent, metadata, _prefix) do
    metadata[:name] || metadata[:agent_module] || "agent"
  end

  defp build_span_name(:llm, metadata, _prefix) do
    model = metadata[:model] || "llm_call"

    case metadata[:iteration] do
      nil -> model
      n -> "#{model} ##{n}"
    end
  end

  defp build_span_name(:tool, metadata, _prefix) do
    metadata[:tool_name] || metadata[:node_name] || metadata[:name] || "tool_call"
  end

  defp build_span_name(:chain, metadata, _prefix) do
    "iteration #{metadata[:iteration] || 1}"
  end

  # -- Helpers --

  defp normalize_messages(messages) when is_list(messages) do
    Enum.map(messages, fn msg ->
      %{
        role: to_string(msg[:role] || Map.get(msg, "role", "unknown")),
        content: msg[:content] || Map.get(msg, "content", "")
      }
    end)
  end

  defp normalize_messages(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp format_exception_message(kind, reason) when is_exception(reason) do
    "#{kind}: #{Exception.message(reason)}"
  end

  defp format_exception_message(kind, reason) when is_binary(reason) do
    "#{kind}: #{reason}"
  end

  defp format_exception_message(kind, reason) do
    "#{kind}: #{inspect(reason)}"
  end
end
