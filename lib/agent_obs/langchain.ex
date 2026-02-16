defmodule AgentObs.LangChain do
  @compile {:no_warn_undefined,
            [
              LangChain.Chains.LLMChain,
              LangChain.LangChainError
            ]}

  @moduledoc """
  High-level helpers for instrumenting LangChain operations with AgentObs.

  This module provides automatic instrumentation for LangChain's `LLMChain`
  via its callback system, eliminating the need for manual telemetry
  instrumentation when using LangChain.

  ## Installation

  Add `:langchain` as a dependency in your `mix.exs`:

      def deps do
        [
          {:agent_obs, "~> 0.1"},
          {:langchain, "~> 0.5"}
        ]
      end

  ## Usage

  ### Recommended: Wrapper Functions

  The simplest approach wraps `LLMChain.run/2` with automatic instrumentation:

      alias LangChain.Chains.LLMChain
      alias LangChain.ChatModels.ChatAnthropic
      alias LangChain.Message

      {:ok, chain} =
        LLMChain.new!(%{
          llm: ChatAnthropic.new!(%{model: "claude-sonnet-4-5-20250929"}),
          messages: [Message.new_system!("You are helpful.")]
        })
        |> LLMChain.add_message(Message.new_user!("Hello!"))
        |> AgentObs.LangChain.run()

  ### With Tool Calls

      alias LangChain.Function

      tool = Function.new!(%{
        name: "calculator",
        description: "Perform calculations",
        parameters_schema: %{
          type: "object",
          properties: %{expression: %{type: "string"}}
        },
        function: fn args, _context -> {:ok, "42"} end
      })

      {:ok, chain} =
        LLMChain.new!(%{
          llm: ChatAnthropic.new!(%{model: "claude-sonnet-4-5-20250929"}),
          messages: [Message.new_user!("What is 6 * 7?")]
        })
        |> LLMChain.add_tools([tool])
        |> AgentObs.LangChain.run(mode: :while_needs_response)

  ### Direct Chain Instrumentation

  For use outside of `run/2` (e.g., when the chain is run by Sagents or
  your own loop), instrument the chain directly:

      chain =
        LLMChain.new!(%{llm: model, messages: messages})
        |> LLMChain.add_tools(tools)
        |> AgentObs.LangChain.instrument()

  This adds callbacks that emit proper `[:agent_obs, :llm, :start/stop]`
  and `[:agent_obs, :tool, :start/stop]` events. To preserve span hierarchy
  across `Task.async` boundaries, attach the OTel context at the task boundary:

      parent_ctx = OpenTelemetry.Ctx.get_current()
      traced_chain = AgentObs.LangChain.instrument(chain)
      Task.async(fn ->
        OpenTelemetry.Ctx.attach(parent_ctx)
        LLMChain.run(traced_chain)
      end)

  ### Manual Callback Integration

  For more control, add the callback handler directly to your chain:

      LLMChain.new!(%{llm: model, messages: messages})
      |> LLMChain.add_callback(AgentObs.LangChain.callbacks())
      |> LLMChain.run()

  When using `callbacks/0` directly (without `run/2`), tool executions are
  traced individually and LLM token usage / message events are emitted
  as proper `[:agent_obs, :llm, :start/stop]` pairs.
  Use `run/2` for full outer span lifecycle management.

  ## Telemetry Events

  ### With `run/2`:
  - `[:agent_obs, :llm, :start]` - When chain execution begins
  - `[:agent_obs, :llm, :stop]` - When chain execution completes (with tokens, messages)
  - `[:agent_obs, :llm, :exception]` - If chain execution fails
  - `[:agent_obs, :tool, :start]` / `[:agent_obs, :tool, :stop]` - Per tool execution

  ### With `callbacks/0` or `instrument/2`:
  - `[:agent_obs, :llm, :start]` / `[:agent_obs, :llm, :stop]` - Per LLM invocation (token usage + messages)
  - `[:agent_obs, :tool, :start]` / `[:agent_obs, :tool, :stop]` - Per tool execution

  ## See Also

  - `LangChain.Chains.LLMChain` - The underlying chain module
  - `LangChain.Chains.ChainCallbacks` - Callback type definitions
  - `AgentObs.trace_llm/3` - Low-level LLM instrumentation
  - `AgentObs.trace_tool/3` - Low-level tool instrumentation
  """

  alias LangChain.Chains.LLMChain

  @doc """
  Wraps `LLMChain.run/2` with automatic AgentObs instrumentation.

  Injects AgentObs callbacks into the chain and wraps the execution in an
  `AgentObs.trace_llm/3` span. Token usage, output messages, and tool calls
  are automatically captured.

  ## Parameters

  - `chain` - An `LLMChain.t()` struct
  - `opts` - Options passed to `LLMChain.run/2` (e.g., `mode: :while_needs_response`)

  ## Returns

  - `{:ok, updated_chain}` - The chain after execution
  - `{:error, updated_chain, error}` - On failure

  ## Behavior

  In `mode: :while_needs_response`, each iteration of the LLM loop creates a
  child LLM span nested under the outer `trace_llm` span, giving visibility
  into multi-turn agent loops with tool calls.

  ## Examples

      {:ok, chain} =
        LLMChain.new!(%{llm: model, messages: messages})
        |> AgentObs.LangChain.run()

      # With tool loop
      {:ok, chain} =
        LLMChain.new!(%{llm: model, messages: messages})
        |> LLMChain.add_tools(tools)
        |> AgentObs.LangChain.run(mode: :while_needs_response)
  """
  @spec run(struct(), keyword()) :: {:ok, struct()} | {:error, struct(), term()}
  def run(chain, opts \\ []) do
    model_name = extract_model_name(chain.llm)
    input_messages = normalize_messages(chain.messages)

    # Use process dictionary to collect metadata from callbacks
    collector_key = {__MODULE__, :metadata_collector, make_ref()}
    Process.put(collector_key, %{tokens: nil, output_messages: [], tool_calls: []})

    obs_callbacks = build_collecting_callbacks(collector_key)

    chain_with_callbacks =
      LLMChain.add_callback(chain, obs_callbacks)

    # In while_needs_response mode, also add instrument callbacks for
    # per-iteration LLM child spans nested under the outer trace_llm span
    chain_with_callbacks =
      if opts[:mode] == :while_needs_response do
        instrument(chain_with_callbacks, trace_tools: false)
      else
        chain_with_callbacks
      end

    result =
      try do
        AgentObs.trace_llm(model_name, %{input_messages: input_messages, type: "chat"}, fn ->
          case LLMChain.run(chain_with_callbacks, opts) do
            {:ok, updated_chain} ->
              collected = Process.get(collector_key, %{})
              stop_metadata = build_stop_metadata(updated_chain, collected)
              {:ok, updated_chain, stop_metadata}

            {:error, updated_chain, error} ->
              {:error, %{chain: updated_chain, error: error}}
          end
        end)
      after
        Process.delete(collector_key)
      end

    case result do
      {:ok, updated_chain, _metadata} ->
        {:ok, updated_chain}

      {:error, %{chain: updated_chain, error: error}} ->
        {:error, updated_chain, error}

      {:error, reason} ->
        {:error, chain, reason}
    end
  end

  @doc """
  Wraps `LLMChain.run/2` with automatic AgentObs instrumentation.

  Like `run/2` but raises on error and returns only the updated chain.

  ## Examples

      chain =
        LLMChain.new!(%{llm: model, messages: messages})
        |> AgentObs.LangChain.run!()
  """
  @spec run!(struct(), keyword()) :: struct()
  def run!(chain, opts \\ []) do
    case run(chain, opts) do
      {:ok, updated_chain} ->
        updated_chain

      {:error, _chain, error} ->
        raise "LangChain.run failed: #{inspect(error)}"
    end
  end

  @doc """
  Instruments a chain with AgentObs callbacks and returns the instrumented chain.

  This is the recommended way to add observability when running chains outside
  of `run/2` (e.g., when the chain is managed by Sagents or a custom loop).

  ## Options

  - `:trace_tools` - Whether to trace tool executions (default: `true`)
  - `:metadata` - Map of metadata to attach to all emitted spans (e.g., `%{agent_name: "my_agent"}`)

  ## Examples

      # Basic usage
      chain = AgentObs.LangChain.instrument(chain)

      # With parent context for Task.async — attach context at the Task boundary
      parent_ctx = OpenTelemetry.Ctx.get_current()
      traced_chain = AgentObs.LangChain.instrument(chain)
      Task.async(fn ->
        OpenTelemetry.Ctx.attach(parent_ctx)
        LLMChain.run(traced_chain)
      end)

      # With custom metadata
      chain = AgentObs.LangChain.instrument(chain, metadata: %{agent_name: "linkage_agent"})
  """
  @spec instrument(struct(), keyword()) :: struct()
  def instrument(chain, opts \\ []) do
    model_name = extract_model_name(chain.llm)
    cb = build_instrument_callbacks(Keyword.put_new(opts, :model, model_name))
    LLMChain.add_callback(chain, cb)
  end

  @doc """
  Returns a callback handler map for use with `LLMChain.add_callback/2`.

  This provides AgentObs instrumentation without wrapping the chain execution.
  LLM token usage and messages are emitted as proper `[:agent_obs, :llm, :start/stop]`
  event pairs. Tool executions are traced individually. For full outer LLM span
  lifecycle management, use `run/2` instead.

  ## Options

  - `:trace_tools` - Whether to trace tool executions (default: `true`)
  - `:metadata` - Map of metadata to attach to emitted spans
  - `:model` - Model name override. If not set, the model is extracted from `chain.llm` at callback time.

  ## Examples

      LLMChain.new!(%{llm: model, messages: messages})
      |> LLMChain.add_callback(AgentObs.LangChain.callbacks())
      |> LLMChain.run()

      # Disable tool tracing
      LLMChain.new!(%{llm: model, messages: messages})
      |> LLMChain.add_callback(AgentObs.LangChain.callbacks(trace_tools: false))
      |> LLMChain.run()
  """
  @spec callbacks(keyword()) :: map()
  def callbacks(opts \\ []) do
    build_instrument_callbacks(opts)
  end

  # -- Private: Shared callback builder for instrument/2 and callbacks/1 --

  defp build_instrument_callbacks(opts) do
    trace_tools = Keyword.get(opts, :trace_tools, true)
    extra_metadata = Keyword.get(opts, :metadata, nil)
    model_override = Keyword.get(opts, :model, nil)

    # Per-invocation state tracked in process dictionary
    cb_ref = make_ref()
    cb_key = {__MODULE__, :instrument_state, cb_ref}

    base = %{
      on_message_processed: fn chain, message ->
        if Map.get(message, :role) == :assistant do
          # LLM just responded — emit LLM :start now so tool spans nest under it
          model = model_override || extract_model_name(chain.llm)
          input_messages = extract_input_messages(chain)
          tool_calls = has_tool_calls?(message)

          start_meta = %{model: model, input_messages: input_messages, type: "chat"}

          start_meta =
            if extra_metadata,
              do: Map.put(start_meta, :metadata, extra_metadata),
              else: start_meta

          :telemetry.execute([:agent_obs, :llm, :start], %{}, start_meta)

          # Store state for :stop emission later
          Process.put(cb_key, %{
            messages: [normalize_message(message)],
            start_time: System.monotonic_time(:nanosecond),
            has_tool_calls: tool_calls,
            tokens: nil
          })
        else
          # Tool result or other message — just accumulate output messages
          update_instrument_state(cb_key, fn state ->
            %{state | messages: state.messages ++ [normalize_message(message)]}
          end)
        end
      end,
      on_llm_token_usage: fn _chain, token_usage ->
        tokens = extract_token_usage(token_usage)

        update_instrument_state(cb_key, fn state ->
          %{state | tokens: tokens}
        end)

        # If no tool calls, close the LLM span now (no tools to wait for)
        state = Process.get(cb_key)

        if state && !state.has_tool_calls do
          close_llm_span(cb_key, extra_metadata)
        end
      end,
      on_tool_response_created: fn _chain, _result_message ->
        # All tools finished — close the LLM span
        close_llm_span(cb_key, extra_metadata)
      end
    }

    if trace_tools do
      Map.merge(base, build_tool_callbacks())
    else
      base
    end
  end

  defp update_instrument_state(key, fun) do
    state =
      Process.get(key, %{messages: [], tokens: nil, start_time: nil, has_tool_calls: false})

    Process.put(key, fun.(state))
    :ok
  end

  defp close_llm_span(cb_key, extra_metadata) do
    case Process.delete(cb_key) do
      nil ->
        :ok

      state ->
        duration =
          case state.start_time do
            nil -> 0
            start -> System.monotonic_time(:nanosecond) - start
          end

        stop_meta = %{
          output_messages: state.messages || [],
          tokens: state.tokens || %{prompt: 0, completion: 0, total: 0}
        }

        stop_meta =
          if extra_metadata, do: Map.put(stop_meta, :metadata, extra_metadata), else: stop_meta

        :telemetry.execute([:agent_obs, :llm, :stop], %{duration: duration}, stop_meta)
    end
  end

  defp extract_input_messages(chain) do
    # chain.messages includes the just-added assistant message as the last element.
    # Everything before that is the input sent to the LLM.
    case chain.messages do
      [] -> []
      msgs -> msgs |> Enum.slice(0..-2//1) |> normalize_messages()
    end
  end

  defp has_tool_calls?(message) do
    case Map.get(message, :tool_calls) do
      nil -> false
      [] -> false
      [_ | _] -> true
      _ -> false
    end
  end

  defp build_tool_callbacks do
    %{
      on_tool_execution_started: fn _chain, tool_call, _function ->
        start_tool_span(tool_call)
      end,
      on_tool_execution_completed: fn _chain, tool_call, tool_result ->
        finish_tool_span(tool_call, {:ok, tool_result})
      end,
      on_tool_execution_failed: fn _chain, tool_call, error ->
        finish_tool_span(tool_call, {:error, error})
      end
    }
  end

  # -- Private: Collecting callbacks for run/2 --

  defp build_collecting_callbacks(collector_key) do
    %{
      on_llm_token_usage: fn _chain, token_usage ->
        update_collector(collector_key, fn state ->
          tokens = extract_token_usage(token_usage)
          # Accumulate tokens across multiple LLM calls in a while_needs_response loop
          existing = state.tokens
          merged = merge_tokens(existing, tokens)
          %{state | tokens: merged}
        end)
      end,
      on_message_processed: fn _chain, message ->
        update_collector(collector_key, fn state ->
          normalized = normalize_message(message)
          %{state | output_messages: state.output_messages ++ [normalized]}
        end)
      end,
      on_tool_call_identified: fn _chain, tool_call, _function ->
        update_collector(collector_key, fn state ->
          tc = %{
            id: tool_call.call_id,
            name: tool_call.name,
            arguments: tool_call.arguments
          }

          %{state | tool_calls: state.tool_calls ++ [tc]}
        end)
      end,
      on_tool_execution_started: fn _chain, tool_call, _function ->
        start_tool_span(tool_call)
      end,
      on_tool_execution_completed: fn _chain, tool_call, tool_result ->
        finish_tool_span(tool_call, {:ok, tool_result})
      end,
      on_tool_execution_failed: fn _chain, tool_call, error ->
        finish_tool_span(tool_call, {:error, error})
      end
    }
  end

  defp update_collector(key, fun) do
    state = Process.get(key, %{tokens: nil, output_messages: [], tool_calls: []})
    Process.put(key, fun.(state))
    :ok
  end

  # -- Private: Tool span management --

  # Tool callbacks fire as paired start/completed or start/failed events.
  # We use trace_tool/3 by storing a continuation in the process dictionary.
  # Since LangChain executes tools synchronously within the callback process,
  # we track by tool call_id.

  defp start_tool_span(tool_call) do
    span_key = {__MODULE__, :tool_span, tool_call.call_id}

    Process.put(span_key, %{
      name: tool_call.name,
      arguments: tool_call.arguments
    })

    :ok
  end

  defp finish_tool_span(tool_call, result) do
    span_key = {__MODULE__, :tool_span, tool_call.call_id}

    span_data =
      case Process.delete(span_key) do
        nil -> %{name: tool_call.name, arguments: tool_call.arguments || %{}}
        data -> data
      end

    emit_tool_event(span_data, result)
  end

  defp emit_tool_event(span_data, result) do
    AgentObs.trace_tool(span_data.name, %{arguments: span_data.arguments || %{}}, fn ->
      case result do
        {:ok, tool_result} ->
          formatted = AgentObs.MessageNormalizer.format_tool_result(tool_result)
          {:ok, formatted, %{result: formatted}}

        {:error, error} ->
          {:error, error}
      end
    end)
  end

  # -- Private: Data extraction helpers --

  defp extract_token_usage(token_usage) when is_struct(token_usage) do
    input = Map.get(token_usage, :input, 0) || 0
    output = Map.get(token_usage, :output, 0) || 0

    %{
      prompt: input,
      completion: output,
      total: input + output
    }
  end

  defp extract_token_usage(_), do: %{prompt: 0, completion: 0, total: 0}

  defp merge_tokens(nil, new), do: new

  defp merge_tokens(existing, new) do
    %{
      prompt: existing.prompt + new.prompt,
      completion: existing.completion + new.completion,
      total: existing.total + new.total
    }
  end

  defp build_stop_metadata(chain, collected) do
    output_messages =
      case collected.output_messages do
        [] -> extract_last_assistant_messages(chain)
        msgs -> msgs
      end

    tokens = collected.tokens || %{prompt: 0, completion: 0, total: 0}

    metadata = %{
      output_messages: output_messages,
      tokens: tokens
    }

    if collected.tool_calls != [] do
      Map.put(metadata, :tool_calls, collected.tool_calls)
    else
      metadata
    end
  end

  defp extract_last_assistant_messages(chain) do
    messages =
      (Map.get(chain, :exchanged_messages, []) ++ Map.get(chain, :messages, []))
      |> Enum.filter(fn msg ->
        Map.get(msg, :role) == :assistant
      end)

    case messages do
      [] -> []
      msgs -> Enum.map(msgs, &normalize_message/1)
    end
  end

  # -- Private: Message normalization (delegates to shared module) --

  defp normalize_messages(messages),
    do: AgentObs.MessageNormalizer.normalize_messages(messages)

  defp normalize_message(message),
    do: AgentObs.MessageNormalizer.normalize_message(message)

  # -- Private: Model name extraction --

  @doc """
  Extracts a human-readable model name from a LangChain LLM struct or string.

  Returns a string in the format `"provider/model"` when the provider can be
  inferred from the struct module (e.g., `ChatAnthropic` -> `"anthropic"`),
  or the raw model string otherwise.

  ## Examples

      iex> llm = %ChatAnthropic{model: "claude-sonnet-4-5-20250929"}
      iex> AgentObs.LangChain.extract_model_name(llm)
      "anthropic/claude-sonnet-4-5-20250929"

      iex> AgentObs.LangChain.extract_model_name("gpt-4o")
      "gpt-4o"
  """
  def extract_model_name(llm) when is_struct(llm) do
    model = Map.get(llm, :model, nil)
    module = llm.__struct__

    provider =
      module
      |> Module.split()
      |> List.last()
      |> extract_provider_from_module_name()

    case {provider, model} do
      {provider, model} when is_binary(provider) and is_binary(model) ->
        "#{provider}/#{model}"

      {nil, model} when is_binary(model) ->
        model

      _ ->
        inspect(llm)
    end
  end

  def extract_model_name(model) when is_binary(model), do: model
  def extract_model_name(model), do: inspect(model)

  defp extract_provider_from_module_name("ChatAnthropic"), do: "anthropic"
  defp extract_provider_from_module_name("ChatOpenAI"), do: "openai"
  defp extract_provider_from_module_name("ChatOpenAIResponses"), do: "openai"
  defp extract_provider_from_module_name("ChatGoogleAI"), do: "google"
  defp extract_provider_from_module_name("ChatVertexAI"), do: "google"
  defp extract_provider_from_module_name("ChatMistralAI"), do: "mistral"
  defp extract_provider_from_module_name("ChatDeepseek"), do: "deepseek"
  defp extract_provider_from_module_name("ChatGrok"), do: "xai"
  defp extract_provider_from_module_name("ChatPerplexity"), do: "perplexity"
  defp extract_provider_from_module_name("ChatOllamaAI"), do: "ollama"
  defp extract_provider_from_module_name("ChatBumblebee"), do: "bumblebee"
  defp extract_provider_from_module_name("ChatOrq"), do: "orq"
  defp extract_provider_from_module_name(_), do: nil
end
