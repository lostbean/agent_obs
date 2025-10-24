defmodule Demo.Agent do
  @moduledoc """
  An instrumented AI agent using ReqLLM with AgentObs observability.

  This agent demonstrates how to use AgentObs.ReqLLM helpers for automatic
  instrumentation with minimal boilerplate code.

  Features:
  - Automatic LLM call instrumentation with `AgentObs.ReqLLM.trace_stream_text/3`
  - Automatic tool execution instrumentation with `AgentObs.ReqLLM.trace_tool_execution/3`
  - Automatic token extraction and tool call parsing
  - Real-time streaming to console
  - Full conversation history management
  """

  use GenServer

  alias ReqLLM.{Context, Tool}

  defstruct [:history, :tools, :model]

  # Get default model from config, which reads from DEFAULT_MODEL env var
  defp default_model do
    Application.get_env(:req_llm, :default_model, "google:gemini-2.5-flash-lite-preview-09-2025")
  end

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

    model = Keyword.get(opts, :model, default_model())
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
          {:ok, final_history, final_response, tools_used} ->
            IO.write("\n")

            # Calculate iterations: 1 if no tools, otherwise count tool usage rounds + 1
            iterations = if tools_used == [], do: 1, else: length(Enum.uniq(tools_used)) + 1

            {:ok, final_response,
             %{
               history: final_history,
               tools_used: tools_used,
               iterations: iterations
             }}

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
    # Use AgentObs.ReqLLM helper for automatic instrumentation
    case AgentObs.ReqLLM.trace_stream_text(model, history.messages, tools: tools) do
      {:ok, stream_response} ->
        # Start iterative tool calling loop (iteration 1)
        handle_llm_response(stream_response, history, tools, model, 1)

      {:error, error} ->
        {:error, error}
    end
  end

  defp handle_llm_response(stream_response, history, tools, model, iteration) do
    # IMPORTANT: Collect chunks ONCE to avoid double-consuming the stream
    # Stream to console while collecting
    chunks =
      stream_response.stream
      |> Enum.map(fn chunk ->
        IO.write(chunk.text)
        chunk
      end)

    # Extract text and tool calls from the SAME chunks list
    text = chunks |> Enum.filter(&(&1.type == :content)) |> Enum.map_join("", & &1.text)
    tool_calls = ReqLLM.StreamResponse.extract_tool_calls(stream_response)

    # Maximum iterations to prevent infinite loops
    max_iterations = 10

    # Handle response based on whether tools were called
    if tool_calls == [] do
      # No tool calls - task complete
      final_history = Context.append(history, Context.assistant(text))
      {:ok, final_history, text, []}
    else
      # Tool calls present - execute them
      IO.write("\n")

      # Process tool calls
      assistant_message = Context.assistant(text, tool_calls: tool_calls)
      history_with_tool_call = Context.append(history, assistant_message)

      # Track which tools were used (for output metadata)
      tools_used = Enum.map(tool_calls, & &1.name)

      # Execute tools and show results
      history_with_results =
        Enum.reduce(tool_calls, history_with_tool_call, fn tool_call, ctx ->
          execute_instrumented_tool(tool_call, tools, ctx)
        end)

      # Check if we've reached max iterations
      if iteration >= max_iterations do
        IO.write("⚠️  Reached max iterations (#{max_iterations}), stopping\n")
        final_history = Context.append(history_with_results, Context.assistant(text))
        {:ok, final_history, text, tools_used}
      else
        # Make another LLM call with tool results
        # IMPORTANT: Must pass tools to subsequent calls so LLM knows they're available!
        IO.write("\n")

        case AgentObs.ReqLLM.trace_stream_text(model, history_with_results.messages, tools: tools) do
          {:ok, next_stream_response} ->
            # Recursively handle response (may contain more tool calls)
            case handle_llm_response(
                   next_stream_response,
                   history_with_results,
                   tools,
                   model,
                   iteration + 1
                 ) do
              {:ok, final_history, final_text, more_tools} ->
                # Merge tools used across iterations
                {:ok, final_history, final_text, tools_used ++ more_tools}

              {:error, error} ->
                {:error, error}
            end

          {:error, error} ->
            {:error, error}
        end
      end
    end
  end

  defp execute_instrumented_tool(tool_call, tools, context) do
    # Find the tool
    tool = Enum.find(tools, fn t -> t.name == tool_call.name end)

    if tool do
      # Use AgentObs.ReqLLM helper for automatic instrumentation
      result = AgentObs.ReqLLM.trace_tool_execution(tool, tool_call)

      case result do
        {:ok, tool_result} ->
          IO.write(
            "🔧 #{tool_call.name}(#{inspect(tool_call.arguments)}) → #{inspect(tool_result)}\n"
          )

          tool_result_msg = Context.tool_result_message(tool_call.name, tool_call.id, tool_result)
          Context.append(context, tool_result_msg)

        {:ok, tool_result, _metadata} ->
          IO.write(
            "🔧 #{tool_call.name}(#{inspect(tool_call.arguments)}) → #{inspect(tool_result)}\n"
          )

          tool_result_msg = Context.tool_result_message(tool_call.name, tool_call.id, tool_result)
          Context.append(context, tool_result_msg)

        {:error, error} ->
          IO.write("❌ #{tool_call.name}: #{inspect(error)}\n")
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
