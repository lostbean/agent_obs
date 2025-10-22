defmodule Demo.Agent do
  @moduledoc """
  An instrumented AI agent using ReqLLM with AgentObs observability.

  This agent wraps the req_llm streaming API with comprehensive AgentObs instrumentation,
  demonstrating how to trace agent loops, tool calls, and LLM interactions.
  """

  use GenServer

  alias ReqLLM.{Context, Tool}

  defstruct [:history, :tools, :model]

  @default_model "anthropic:claude-sonnet-4-20250514"

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Send a prompt to the agent and get a response.
  """
  def prompt(pid, message) when is_binary(message) do
    GenServer.call(pid, {:prompt, message}, 60_000)
  end

  def prompt(pid, model, message) when is_binary(model) and is_binary(message) do
    GenServer.call(pid, {:prompt, model, message}, 60_000)
  end

  # Server callbacks

  @impl true
  def init(opts) do
    system_prompt =
      Keyword.get(opts, :system_prompt, """
      You are a helpful AI assistant with access to tools.

      When you need to compute math, use the calculator tool with the expression parameter.

      Do not wrap arguments in code fences. Do not include extra text in arguments.

      When you need to search for information, use the web_search tool with a relevant query.

      Always use tools when appropriate and provide clear, helpful responses.
      """)

    model = Keyword.get(opts, :model, @default_model)
    tools = setup_tools()

    history = Context.new([Context.system(system_prompt)])

    {:ok, %__MODULE__{history: history, tools: tools, model: model}}
  end

  @impl true
  def handle_call({:prompt, message}, from, %{model: model} = state) do
    handle_call({:prompt, model, message}, from, state)
  end

  @impl true
  def handle_call({:prompt, model, message}, _from, state) do
    # Instrument the entire agent execution with AgentObs
    result =
      AgentObs.trace_agent("llm_agent", %{input: message, model: model}, fn ->
        new_history = Context.append(state.history, Context.user(message))

        case stream_and_handle_tools(model, new_history, state.tools) do
          {:ok, final_history, final_response} ->
            IO.write("\n")
            {:ok, final_response, %{history: final_history}}

          {:error, error} ->
            IO.write("Error: #{inspect(error)}\n")
            {:error, error}
        end
      end)

    case result do
      {:ok, final_response, %{history: final_history}} ->
        {:reply, {:ok, final_response}, %{state | history: final_history}}

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  # Private functions

  defp stream_and_handle_tools(model, history, tools) do
    # Instrument the LLM call
    result =
      AgentObs.trace_llm(model, %{input_messages: history.messages, type: "chat"}, fn ->
        case ReqLLM.stream_text(model, history.messages, tools: tools) do
          {:ok, stream_response} ->
            # Stream chunks to console in real-time and collect for processing
            chunks =
              stream_response.stream
              |> Enum.map(fn chunk ->
                # Stream to console immediately
                IO.write(chunk.text)
                chunk
              end)

            tool_calls = extract_tool_calls_from_chunks(chunks)
            text = chunks |> Enum.map_join("", & &1.text)

            # Extract token usage from stream response metadata
            tokens = extract_token_usage(stream_response)

            output_messages =
              if tool_calls != [] do
                [%{role: "assistant", content: text, tool_calls: tool_calls}]
              else
                [%{role: "assistant", content: text}]
              end

            {:ok, text,
             %{
               tool_calls: tool_calls,
               history: history,
               output_messages: output_messages,
               tokens: tokens
             }}

          {:error, error} ->
            {:error, error}
        end
      end)

    case result do
      {:ok, text, %{tool_calls: [], history: history}} ->
        final_history = Context.append(history, Context.assistant(text))
        {:ok, final_history, text}

      {:ok, initial_text, %{tool_calls: tool_calls, history: history}} ->
        # Process tool calls
        assistant_message = Context.assistant(initial_text, tool_calls: tool_calls)
        history_with_tool_call = Context.append(history, assistant_message)

        IO.write("\n")

        # Execute tools and show results
        history_with_results =
          Enum.reduce(tool_calls, history_with_tool_call, fn tool_call, ctx ->
            execute_instrumented_tool(tool_call, tools, ctx)
          end)

        # Second LLM call with tool results
        case stream_final_response(model, history_with_results) do
          {:ok, final_history, final_text} ->
            {:ok, final_history, final_text}

          {:error, error} ->
            {:error, error}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp execute_instrumented_tool(tool_call, tools, context) do
    # Find the tool
    tool = Enum.find(tools, fn t -> t.name == tool_call.name end)

    if tool do
      # Instrument tool execution
      result =
        AgentObs.trace_tool(tool_call.name, %{arguments: tool_call.arguments}, fn ->
          case ReqLLM.Tool.execute(tool, tool_call.arguments) do
            {:ok, result} ->
              IO.write(
                "🔧 #{tool_call.name}(#{inspect(tool_call.arguments)}) → #{inspect(result)}\n"
              )

              {:ok, result}

            {:error, error} ->
              IO.write("❌ #{tool_call.name}: #{inspect(error)}\n")
              {:error, error}
          end
        end)

      case result do
        {:ok, tool_result} ->
          tool_result_msg = Context.tool_result_message(tool_call.name, tool_call.id, tool_result)
          Context.append(context, tool_result_msg)

        {:error, error} ->
          error_result = %{error: "Tool execution failed: #{inspect(error)}"}

          tool_result_msg =
            Context.tool_result_message(tool_call.name, tool_call.id, error_result)

          Context.append(context, tool_result_msg)
      end
    else
      IO.write("❌ Tool #{tool_call.name} not found\n")
      context
    end
  end

  defp stream_final_response(model, history) do
    # Second LLM call to get final response with tool results
    result =
      AgentObs.trace_llm(model, %{input_messages: history.messages, type: "chat"}, fn ->
        case ReqLLM.stream_text(model, history.messages) do
          {:ok, stream_response} ->
            IO.write("\n")

            # Stream final response to console in real-time
            final_chunks =
              stream_response.stream
              |> Enum.map(fn chunk ->
                # Stream to console immediately
                IO.write(chunk.text)
                chunk
              end)

            final_text = final_chunks |> Enum.map_join("", & &1.text)

            # Extract token usage
            tokens = extract_token_usage(stream_response)

            {:ok, final_text,
             %{
               output_messages: [%{role: "assistant", content: final_text}],
               tokens: tokens
             }}

          {:error, error} ->
            {:error, error}
        end
      end)

    case result do
      {:ok, final_text, _metadata} ->
        final_history = Context.append(history, Context.assistant(final_text))
        {:ok, final_history, final_text}

      {:error, error} ->
        {:error, error}
    end
  end

  defp extract_tool_calls_from_chunks(chunks) do
    # Base tool calls with index
    tool_calls =
      chunks
      |> Enum.filter(&(&1.type == :tool_call))
      |> Enum.map(fn chunk ->
        %{
          id: Map.get(chunk.metadata, :id) || "call_#{:erlang.unique_integer()}",
          name: chunk.name,
          arguments: chunk.arguments || %{},
          index: Map.get(chunk.metadata, :index, 0)
        }
      end)

    # Collect argument fragments from meta chunks
    arg_fragments =
      chunks
      |> Enum.filter(&(&1.type == :meta))
      |> Enum.filter(&Map.has_key?(&1.metadata, :tool_call_args))
      |> Enum.group_by(& &1.metadata.tool_call_args.index)
      |> Map.new(fn {index, fragments} ->
        # Handle both :partial_json (older) and :fragment (newer) keys
        args_json =
          fragments
          |> Enum.map_join("", fn frag ->
            Map.get(frag.metadata.tool_call_args, :partial_json) ||
              Map.get(frag.metadata.tool_call_args, :fragment) ||
              ""
          end)

        # Only decode if we have content
        if args_json != "" do
          {index, Jason.decode!(args_json)}
        else
          {index, %{}}
        end
      end)

    # Merge argument fragments into tool calls
    tool_calls
    |> Enum.map(fn tc ->
      if Map.has_key?(arg_fragments, tc.index) do
        %{tc | arguments: arg_fragments[tc.index]}
      else
        tc
      end
    end)
  end

  defp extract_token_usage(stream_response) do
    # ReqLLM provides usage data through ReqLLM.StreamResponse.usage/1
    case ReqLLM.StreamResponse.usage(stream_response) do
      %{input_tokens: input, output_tokens: output} ->
        %{
          prompt: input || 0,
          completion: output || 0,
          total: (input || 0) + (output || 0)
        }

      _ ->
        # If no usage data available, return zeros
        %{prompt: 0, completion: 0, total: 0}
    end
  end

  defp setup_tools do
    [
      Tool.new!(
        name: "calculator",
        description:
          "Perform mathematical calculations. Prefer structured arguments: " <>
            ~s|{"operation":"multiply","operands":[15,7]}| <>
            ". As a fallback, you may pass an expression string: " <>
            ~s|{"expression":"15 * 7 + 23"}| <>
            ". Valid operations: add, subtract, multiply, divide, power, sqrt.",
        parameter_schema: [
          operation: [
            type: :string,
            required: false,
            doc: "One of: add, subtract, multiply, divide, power, sqrt"
          ],
          operands: [
            type: {:list, :any},
            required: false,
            doc: "Numbers to operate on. For sqrt, pass a single number; for others, pass 2+."
          ],
          expression: [
            type: :string,
            required: false,
            doc: "Optional fallback. Examples: '15 * 7 + 23', '10 * 5', 'sqrt(16)'."
          ]
        ],
        callback: &calculator_callback/1
      ),
      Tool.new!(
        name: "web_search",
        description: "Search the web for information",
        parameter_schema: [
          query: [type: :string, required: true, doc: "Search query"]
        ],
        callback: fn
          %{"query" => query} when is_binary(query) ->
            {:ok, "Mock search results for: #{query}"}

          %{query: query} when is_binary(query) ->
            {:ok, "Mock search results for: #{query}"}

          args ->
            {:error, "Invalid arguments: #{inspect(args)}"}
        end
      )
    ]
  end

  defp calculator_callback(%{expression: expr}) when is_binary(expr) do
    {result, _} = Code.eval_string(expr)
    {:ok, result}
  rescue
    e -> {:error, "Invalid expression: #{Exception.message(e)}"}
  end

  defp calculator_callback(%{operation: op, operands: ops}) when is_list(ops) do
    with :ok <- validate_operation(op),
         {:ok, nums} <- cast_numbers(ops) do
      compute(op, nums)
    end
  end

  defp calculator_callback(%{"expression" => expr}) when is_binary(expr) do
    calculator_callback(%{expression: expr})
  end

  defp calculator_callback(%{"operation" => op, "operands" => ops}) when is_list(ops) do
    calculator_callback(%{operation: op, operands: ops})
  end

  defp calculator_callback(args) do
    {:error,
     "Provide either {operation, operands} or {expression}. Examples: " <>
       ~s|{"operation":"multiply","operands":[15,7]}| <>
       " or " <>
       ~s|{"expression":"15 * 7 + 23"}| <> ". Got: #{inspect(args)}"}
  end

  defp validate_operation(op)
       when op in ["add", "subtract", "multiply", "divide", "power", "sqrt"] do
    :ok
  end

  defp validate_operation(op),
    do: {:error, "Invalid operation: #{op}. Valid: add, subtract, multiply, divide, power, sqrt"}

  defp cast_numbers(ops) do
    nums =
      Enum.map(ops, fn
        n when is_integer(n) -> n * 1.0
        n when is_float(n) -> n
        s when is_binary(s) -> String.to_float(s)
      end)

    {:ok, nums}
  rescue
    _ -> {:error, "All operands must be numbers"}
  end

  defp compute("add", nums), do: {:ok, Enum.sum(nums)}
  defp compute("subtract", [a, b]), do: {:ok, a - b}
  defp compute("multiply", nums), do: {:ok, Enum.reduce(nums, 1, &(&1 * &2))}
  defp compute("divide", [a, b]) when b != 0, do: {:ok, a / b}
  defp compute("divide", [_, 0]), do: {:error, "Division by zero"}
  defp compute("power", [a, b]), do: {:ok, :math.pow(a, b)}
  defp compute("sqrt", [a]) when a >= 0, do: {:ok, :math.sqrt(a)}
  defp compute("sqrt", [a]), do: {:error, "Cannot take square root of negative number: #{a}"}

  defp compute(op, ops),
    do: {:error, "Operation #{op} not supported with #{length(ops)} operands"}

  # Handle streaming completion messages
  @impl true
  def handle_info({:stream_task_completed, _context}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({ref, :ok}, state) when is_reference(ref) do
    {:noreply, state}
  end

  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
