defmodule AgentObs do
  @moduledoc """
  A production-grade Elixir library for LLM agent observability.

  AgentObs provides a simple, powerful, and idiomatic interface for instrumenting
  LLM agentic applications with telemetry events. It supports multiple observability
  backends through a pluggable handler architecture.

  ## Architecture

  AgentObs uses a two-layer architecture:

  **Layer 1: Core Telemetry API (Backend-Agnostic)**
  - Leverages Elixir's native `:telemetry` ecosystem
  - Provides high-level helpers for instrumenting agent operations
  - Defines standardized event schemas

  **Layer 2: Pluggable Backend Handlers**
  - Phoenix handler with OpenInference semantic conventions
  - Generic OpenTelemetry handler
  - Extensible to other platforms (Langfuse, Datadog, etc.)

  ## Quick Start

      # Configure in config/config.exs
      config :agent_obs,
        enabled: true,
        handlers: [AgentObs.Handlers.Phoenix]

      # Instrument your agent
      defmodule MyAgent do
        def run(query) do
          AgentObs.trace_agent("my_agent", %{input: query}, fn ->
            # Agent logic here
            result = do_agent_work(query)
            {:ok, result, %{iterations: 1}}
          end)
        end

        defp do_agent_work(query) do
          AgentObs.trace_llm("gpt-4o", %{
            input_messages: [%{role: "user", content: query}]
          }, fn ->
            response = call_llm(query)
            {:ok, response, %{tokens: %{prompt: 10, completion: 25}}}
          end)
        end
      end

  ## High-Level Instrumentation Helpers

  - `trace_agent/3` - Instruments agent loops or invocations
  - `trace_tool/3` - Instruments tool calls
  - `trace_llm/3` - Instruments LLM API calls
  - `trace_prompt/3` - Instruments prompt template rendering

  ## Low-Level API

  - `emit/2` - Emits custom telemetry events
  - `configure/1` - Runtime configuration updates
  """

  require Logger

  alias AgentObs.Events

  @type trace_result :: term()
  @type metadata :: map()
  @type trace_fun :: (-> trace_result())

  @doc """
  Instruments an agent loop or agent invocation.

  Wraps the agent logic in a telemetry span, automatically emitting start, stop,
  and exception events with standardized metadata.

  ## Parameters

  - `name` - Human-readable name for the agent operation
  - `metadata` - Context about the agent invocation
    - `:input` (required) - The input/query/task given to the agent
    - `:model` (optional) - The routing or orchestration model used
    - `:metadata` (optional) - Additional custom metadata
  - `fun` - The agent logic to execute

  ## Return Value

  The function should return one of:
  - `{:ok, output}` - Success with output only
  - `{:ok, output, metadata}` - Success with output and additional metadata
  - `{:error, reason}` - Failure

  ## Examples

      AgentObs.trace_agent("weather_assistant", %{input: "What's the weather?"}, fn ->
        result = perform_weather_lookup()
        {:ok, result, %{tools_used: ["weather_api"], iterations: 2}}
      end)
  """
  @spec trace_agent(String.t(), metadata(), trace_fun()) :: trace_result()
  def trace_agent(name, metadata, fun) when is_binary(name) and is_function(fun, 0) do
    start_metadata = Map.merge(metadata, %{name: name})

    with :ok <- Events.validate_event(:agent, :start, start_metadata) do
      event_name = event_prefix() ++ [:agent]

      :telemetry.span(event_name, start_metadata, fn ->
        case safe_execute(fun) do
          {:ok, output} ->
            stop_metadata = %{output: output}
            {{:ok, output}, stop_metadata}

          {:ok, output, extra_metadata} ->
            stop_metadata = Map.put(extra_metadata, :output, output)
            {{:ok, output, extra_metadata}, stop_metadata}

          {:error, reason} = error ->
            stop_metadata = %{error: reason}
            {error, stop_metadata}

          other ->
            stop_metadata = %{output: other}
            {other, stop_metadata}
        end
      end)
    else
      {:error, reason} ->
        Logger.warning("Invalid agent metadata: #{reason}")
        fun.()
    end
  end

  @doc """
  Instruments a tool call or function execution within an agent.

  ## Parameters

  - `tool_name` - Name of the tool being invoked
  - `metadata` - Tool invocation context
    - `:arguments` (required) - The arguments passed to the tool (map or JSON string)
    - `:description` (optional) - Tool description
  - `fun` - The tool execution logic

  ## Return Value

  The function should return one of:
  - `{:ok, result}` - Success with result
  - `{:ok, result, metadata}` - Success with result and additional metadata
  - `{:error, reason}` - Failure

  ## Examples

      AgentObs.trace_tool("get_weather", %{arguments: %{city: "SF"}}, fn ->
        {:ok, %{temp: 72, condition: "sunny"}}
      end)
  """
  @spec trace_tool(String.t(), metadata(), trace_fun()) :: trace_result()
  def trace_tool(tool_name, metadata, fun) when is_binary(tool_name) and is_function(fun, 0) do
    start_metadata = Map.merge(metadata, %{name: tool_name})

    with :ok <- Events.validate_event(:tool, :start, start_metadata) do
      event_name = event_prefix() ++ [:tool]

      :telemetry.span(event_name, start_metadata, fn ->
        case safe_execute(fun) do
          {:ok, result} ->
            stop_metadata = %{result: result}
            {{:ok, result}, stop_metadata}

          {:ok, result, extra_metadata} ->
            stop_metadata = Map.put(extra_metadata, :result, result)
            {{:ok, result, extra_metadata}, stop_metadata}

          {:error, reason} = error ->
            stop_metadata = %{error: reason}
            {error, stop_metadata}

          other ->
            stop_metadata = %{result: other}
            {other, stop_metadata}
        end
      end)
    else
      {:error, reason} ->
        Logger.warning("Invalid tool metadata: #{reason}")
        fun.()
    end
  end

  @doc """
  Instruments an LLM API call (chat completion, embedding, etc.).

  ## Parameters

  - `model` - The LLM model identifier (e.g., "gpt-4o", "claude-3-opus")
  - `metadata` - LLM call context
    - `:input_messages` (required for chat) - List of message maps with `:role` and `:content`
    - `:type` (optional) - "chat", "completion", "embedding" (default: "chat")
    - `:temperature`, `:max_tokens`, etc. - Model parameters
  - `fun` - The LLM API call logic

  ## Return Value

  The function should return `{:ok, response, metadata}` where metadata includes:
  - `:output_messages` - Response messages
  - `:tokens` - Token usage map with `:prompt`, `:completion`, `:total`
  - `:cost` - Cost in USD (optional)

  ## Examples

      AgentObs.trace_llm("gpt-4o", %{
        input_messages: [%{role: "user", content: "Hello"}]
      }, fn ->
        response = call_openai_api()
        {:ok, response.content, %{
          output_messages: [%{role: "assistant", content: response.content}],
          tokens: %{prompt: 10, completion: 25},
          cost: 0.00015
        }}
      end)
  """
  @spec trace_llm(String.t(), metadata(), trace_fun()) :: trace_result()
  def trace_llm(model, metadata, fun) when is_binary(model) and is_function(fun, 0) do
    start_metadata = Map.put(metadata, :model, model)
    normalized_start = Events.normalize_metadata(:llm, :start, start_metadata)

    with :ok <- Events.validate_event(:llm, :start, normalized_start) do
      event_name = event_prefix() ++ [:llm]

      :telemetry.span(event_name, normalized_start, fn ->
        case safe_execute(fun) do
          {:ok, response, stop_metadata} ->
            normalized_stop = Events.normalize_metadata(:llm, :stop, stop_metadata)
            {{:ok, response, stop_metadata}, normalized_stop}

          {:error, reason} = error ->
            stop_metadata = %{error: reason}
            {error, stop_metadata}

          other ->
            {other, %{}}
        end
      end)
    else
      {:error, reason} ->
        Logger.warning("Invalid LLM metadata: #{reason}")
        fun.()
    end
  end

  @doc """
  Instruments prompt construction or template rendering.

  ## Parameters

  - `template_name` - Name of the prompt template
  - `metadata` - Template rendering context
    - `:variables` (required) - Variables used in template rendering
    - `:template` (optional) - The template string itself
  - `fun` - The prompt rendering logic

  ## Return Value

  The function should return `{:ok, rendered_prompt}` or `{:ok, rendered_prompt, metadata}`.

  ## Examples

      AgentObs.trace_prompt("system_prompt", %{
        variables: %{user_name: "Alice", task: "weather"}
      }, fn ->
        {:ok, render_template(@system_template, variables)}
      end)
  """
  @spec trace_prompt(String.t(), metadata(), trace_fun()) :: trace_result()
  def trace_prompt(template_name, metadata, fun)
      when is_binary(template_name) and is_function(fun, 0) do
    start_metadata = Map.merge(metadata, %{name: template_name})

    with :ok <- Events.validate_event(:prompt, :start, start_metadata) do
      event_name = event_prefix() ++ [:prompt]

      :telemetry.span(event_name, start_metadata, fn ->
        case safe_execute(fun) do
          {:ok, rendered} ->
            stop_metadata = %{rendered: rendered}
            {{:ok, rendered}, stop_metadata}

          {:ok, rendered, extra_metadata} ->
            stop_metadata = Map.put(extra_metadata, :rendered, rendered)
            {{:ok, rendered, extra_metadata}, stop_metadata}

          {:error, reason} = error ->
            stop_metadata = %{error: reason}
            {error, stop_metadata}

          other ->
            stop_metadata = %{rendered: other}
            {other, stop_metadata}
        end
      end)
    else
      {:error, reason} ->
        Logger.warning("Invalid prompt metadata: #{reason}")
        fun.()
    end
  end

  @doc """
  Emits a custom telemetry event with AgentObs standardized metadata.

  For advanced use cases not covered by the high-level helpers.

  ## Parameters

  - `event_type` - One of `:agent`, `:tool`, `:llm`, `:prompt`, or a custom atom
  - `metadata` - Event-specific metadata

  ## Examples

      AgentObs.emit(:custom_event, %{
        name: "vector_search",
        input: query,
        output: results,
        metadata: %{index: "docs", k: 10}
      })
  """
  @spec emit(atom(), metadata()) :: :ok
  def emit(event_type, metadata) when is_atom(event_type) and is_map(metadata) do
    event_name = event_prefix() ++ [event_type]
    :telemetry.execute(event_name, %{}, metadata)
  end

  @doc """
  Runtime configuration of handlers and options.

  ## Parameters

  - `opts` - Keyword list of configuration options
    - `:handlers` - List of handler modules to enable
    - `:event_prefix` - Custom event prefix (default: `[:agent_obs]`)
    - `:enabled` - Enable/disable instrumentation (default: `true`)

  ## Examples

      AgentObs.configure(
        handlers: [AgentObs.Handlers.Phoenix],
        event_prefix: [:my_app, :ai]
      )
  """
  @spec configure(keyword()) :: :ok
  def configure(opts) when is_list(opts) do
    Enum.each(opts, fn
      {:handlers, handlers} ->
        Application.put_env(:agent_obs, :handlers, handlers)

      {:event_prefix, prefix} ->
        Application.put_env(:agent_obs, :event_prefix, prefix)

      {:enabled, enabled} ->
        Application.put_env(:agent_obs, :enabled, enabled)

      {key, _value} ->
        Logger.warning("Unknown AgentObs configuration key: #{key}")
    end)

    :ok
  end

  # Private helpers

  defp event_prefix do
    Application.get_env(:agent_obs, :event_prefix, [:agent_obs])
  end

  defp safe_execute(fun) do
    fun.()
  rescue
    exception ->
      {:error, exception}
  end
end
