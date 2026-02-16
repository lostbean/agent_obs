defmodule AgentObs.Sagents do
  @compile {:no_warn_undefined, [Sagents.Middleware, Sagents.AgentContext]}

  @moduledoc """
  Observability middleware for the Sagents agent framework.

  This module implements `Sagents.Middleware` to automatically instrument
  Sagents agents with AgentObs telemetry, providing visibility into agent
  execution, LLM calls, and tool usage.

  ## Installation

  Add both `:sagents` and `:agent_obs` as dependencies in your `mix.exs`:

      def deps do
        [
          {:agent_obs, "~> 0.2"},
          {:sagents, "~> 0.2"}
        ]
      end

  ## Usage

  Add this middleware to your agent's middleware stack:

      alias Sagents.Agent
      alias LangChain.ChatModels.ChatAnthropic

      {:ok, agent} = Agent.new(%{
        agent_id: "my-agent",
        model: ChatAnthropic.new!(%{model: "claude-sonnet-4-5-20250929"}),
        middleware: [
          AgentObs.Sagents,
          Sagents.Middleware.TodoList,
          Sagents.Middleware.FileSystem
        ]
      })

  For best timing accuracy, place `AgentObs.Sagents` **first** in the
  middleware list so `before_model` captures the full pipeline duration.

  ### With Options

      {:ok, agent} = Agent.new(%{
        model: model,
        middleware: [
          {AgentObs.Sagents, [trace_tools: true]},
          Sagents.Middleware.TodoList
        ]
      })

  ## What Gets Traced

  - **LLM calls**: Each iteration of the agent loop emits
    `[:agent_obs, :llm, :start]` / `[:agent_obs, :llm, :stop]` events with
    input/output messages, token usage, and model name.
  - **Tool calls**: Automatically traced via `callbacks/1` — no external
    `extra_callbacks` wiring needed.
  - **Agent lifecycle**: `on_server_start` emits an agent start event.
  - **Span hierarchy**: `on_fork_context/2` propagates OTel context to
    sub-agent processes for proper parent-child span relationships.

  ## Options

  - `:trace_tools` - Whether to inject LangChain callbacks for tool tracing
    (default: `true`). When enabled, tool executions within the agent loop
    are individually traced.
  - `:metadata` - Map of metadata to attach to emitted spans

  ## Self-Contained Observability

  As of v0.2.1, this middleware is fully self-contained. Adding it to your
  middleware stack provides complete observability (agent spans, LLM spans,
  tool spans, and cross-process span hierarchy) without any external wiring:

      middleware: [
        AgentObs.Sagents,          # All observability handled here
        Sagents.Middleware.SubAgent # Sub-agents inherit OTel context
      ]

  Previously, consumers had to wire `extra_callbacks: AgentObs.LangChain.callbacks()`
  separately. This is no longer needed — `callbacks/1` returns the LangChain
  callback handlers automatically, and `on_fork_context/2` handles OTel context
  propagation to sub-agent processes.

  ## How It Works

  The middleware uses `before_model` / `after_model` hooks which fire on
  **every iteration** of the agent's execution loop:

  1. `before_model` records the current message count and start time
  2. The LLM processes the request (possibly with tool calls)
  3. `after_model` detects new messages added by the LLM, extracts token
     usage, and emits a complete `trace_llm` span

  This approach captures each LLM round-trip individually, giving you
  visibility into multi-turn agent loops.
  """

  @behaviour Sagents.Middleware

  @impl true
  def init(opts) do
    config = %{
      agent_id: Keyword.get(opts, :agent_id),
      model: Keyword.get(opts, :model),
      trace_tools: Keyword.get(opts, :trace_tools, true)
    }

    {:ok, config}
  end

  @impl true
  def on_server_start(state, config) do
    agent_id = config.agent_id || Map.get(state, :agent_id, "unknown")

    AgentObs.emit(:agent, %{
      name: agent_id,
      input: "agent_started",
      event: :server_start
    })

    {:ok, state}
  end

  @impl true
  def before_model(state, config) do
    agent_id = config.agent_id || Map.get(state, :agent_id, "unknown")
    messages = Map.get(state, :messages, [])
    first_user_msg = find_first_user_content(messages)
    start_time = System.monotonic_time(:nanosecond)

    # Emit an AGENT :start event NOW so the Phoenix handler opens an OTel span.
    # LLM and tool spans emitted during execution (between before_model and
    # after_model) will become children of this agent span.
    :telemetry.execute(
      [:agent_obs, :agent, :start],
      %{},
      %{
        name: agent_id,
        input: first_user_msg,
        model: extract_model_name(config.model),
        start_time: start_time
      }
    )

    # Store metadata for after_model to close the span
    span_key = {__MODULE__, :agent_span, config.agent_id}

    Process.put(span_key, %{
      model: extract_model_name(config.model),
      message_count_before: length(messages),
      start_time: start_time
    })

    {:ok, state}
  end

  @impl true
  def after_model(state, config) do
    span_key = {__MODULE__, :agent_span, config.agent_id}

    case Process.delete(span_key) do
      nil ->
        {:ok, state}

      span_data ->
        close_agent_span(state, span_data)
        {:ok, state}
    end
  end

  @impl true
  def tools(_config) do
    []
  end

  @doc """
  Return LangChain callback handlers for tool/LLM tracing.

  Delegates to `AgentObs.LangChain.callbacks/1`, forwarding relevant config.
  This makes `AgentObs.Sagents` self-contained: consumers add it to their
  middleware stack and get full observability (agent + LLM + tool spans)
  without any external `extra_callbacks` wiring.
  """
  @impl true
  def callbacks(config) do
    opts = [
      trace_tools: Map.get(config, :trace_tools, true),
      metadata: Map.get(config, :metadata, %{})
    ]

    AgentObs.LangChain.callbacks(opts)
  end

  @doc """
  Propagate OTel span context to sub-agent processes.

  Sagents calls this when forking context for a child agent process.
  We snapshot the current OTel context and register a restore function
  that will re-attach it in the child process when `AgentContext.init/1`
  runs. This creates proper parent-child span relationships across
  process boundaries.

  Gracefully no-ops when OpenTelemetry is not loaded.
  """
  @impl true
  def on_fork_context(context, _config) do
    if otel_available?() do
      otel_ctx = OpenTelemetry.Ctx.get_current()
      context = Map.put(context, :otel_ctx, otel_ctx)

      Sagents.AgentContext.add_restore_fn(context, fn ctx ->
        OpenTelemetry.Ctx.attach(ctx[:otel_ctx])
      end)
    else
      context
    end
  end

  # -- Private: Agent span closure --

  defp close_agent_span(state, span_data) do
    messages = Map.get(state, :messages, [])

    # Extract the final assistant response as output
    output = find_last_assistant_content(messages, span_data.message_count_before)

    # Extract token usage from the last assistant message metadata if available
    tokens = extract_tokens_from_messages(messages, span_data.message_count_before)

    duration = System.monotonic_time(:nanosecond) - span_data.start_time

    # Emit only :stop — the :start was already emitted in before_model
    # so the OTel span has been open during the entire execution,
    # allowing LLM and tool spans to become children.
    :telemetry.execute(
      [:agent_obs, :agent, :stop],
      %{duration: duration},
      %{output: output, tokens: tokens}
    )
  end

  # -- Private: Token extraction --

  defp extract_tokens_from_messages(messages, offset) do
    new_messages = Enum.drop(messages, offset)

    # Look for token usage in message metadata
    usage =
      new_messages
      |> Enum.filter(fn msg -> Map.get(msg, :role) == :assistant end)
      |> Enum.reduce(%{input: 0, output: 0}, fn msg, acc ->
        case get_in(msg, [Access.key(:metadata, %{}), Access.key(:usage, nil)]) do
          %{input: input, output: output} ->
            %{input: acc.input + (input || 0), output: acc.output + (output || 0)}

          _ ->
            acc
        end
      end)

    %{
      prompt: usage.input,
      completion: usage.output,
      total: usage.input + usage.output
    }
  end

  # -- Private: Message content extraction --

  defp find_first_user_content(messages) do
    case Enum.find(messages, &(Map.get(&1, :role) == :user)) do
      nil -> ""
      msg -> extract_content(msg)
    end
  end

  defp find_last_assistant_content(messages, offset) do
    messages
    |> Enum.drop(offset)
    |> Enum.filter(&(Map.get(&1, :role) == :assistant))
    |> List.last()
    |> case do
      nil -> ""
      msg -> extract_content(msg)
    end
  end

  defp extract_content(msg) do
    case Map.get(msg, :content) do
      c when is_binary(c) -> c
      parts when is_list(parts) -> extract_text_from_parts(parts)
      _ -> inspect(Map.get(msg, :content, ""))
    end
  end

  defp extract_text_from_parts(parts) do
    parts
    |> Enum.filter(fn
      %{type: :text} -> true
      _ -> false
    end)
    |> Enum.map_join("\n", & &1.content)
  end

  # -- Private: Model name extraction --

  defp extract_model_name(nil), do: "unknown"

  defp extract_model_name(llm) when is_struct(llm) do
    AgentObs.LangChain.extract_model_name(llm)
  end

  defp extract_model_name(model) when is_binary(model), do: model
  defp extract_model_name(model), do: inspect(model)

  defp otel_available? do
    Code.ensure_loaded?(OpenTelemetry.Ctx)
  end
end
