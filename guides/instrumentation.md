# Instrumentation Guide

This guide covers best practices and patterns for instrumenting your LLM
applications with AgentObs.

## Table of Contents

- [Core Concepts](#core-concepts)
- [Instrumentation Patterns](#instrumentation-patterns)
- [Best Practices](#best-practices)
- [Advanced Techniques](#advanced-techniques)
- [Common Pitfalls](#common-pitfalls)

## Core Concepts

### Event Types

AgentObs provides four primary event types:

1. **Agent Events** - High-level agent loops or workflows
2. **LLM Events** - Language model API calls
3. **Tool Events** - Tool/function executions
4. **Prompt Events** - Prompt template rendering

### Span Hierarchy

Spans create a parent-child relationship automatically based on nesting:

```elixir
AgentObs.trace_agent("my_agent", ..., fn ->
  # This creates a parent span

  AgentObs.trace_llm("gpt-4o", ..., fn ->
    # This becomes a child of the agent span
  end)

  AgentObs.trace_tool("calculator", ..., fn ->
    # This is also a child of the agent span
  end)
end)
```

Results in:

```
my_agent
├── gpt-4o (LLM call)
└── calculator (tool call)
```

## Instrumentation Patterns

### Pattern 1: Simple Agent

A basic agent with single LLM call:

```elixir
defmodule MyApp.SimpleAgent do
  def run(query) do
    AgentObs.trace_agent("simple_agent", %{input: query}, fn ->
      result = call_llm(query)
      {:ok, result, %{iterations: 1}}
    end)
  end

  defp call_llm(query) do
    AgentObs.trace_llm("gpt-4o", %{
      input_messages: [%{role: "user", content: query}]
    }, fn ->
      response = OpenAI.chat_completion(...)

      {:ok, response.message, %{
        output_messages: [response.message],
        tokens: %{
          prompt: response.usage.prompt_tokens,
          completion: response.usage.completion_tokens,
          total: response.usage.total_tokens
        }
      }}
    end)
  end
end
```

### Pattern 2: Agent with Tools (ReAct Loop)

An agent that can use tools in a reasoning loop. This example uses ReqLLM for
automatic tool call handling:

```elixir
defmodule MyApp.ToolAgent do
  alias ReqLLM.{Context, Tool}

  def run(query, model \\ "anthropic:claude-3-5-sonnet") do
    AgentObs.trace_agent("tool_agent", %{input: query, model: model}, fn ->
      # Initialize conversation with system prompt
      history = Context.new([
        Context.system("You are a helpful assistant with access to tools.")
      ])
      history = Context.append(history, Context.user(query))

      # Get available tools
      tools = setup_tools()

      # Run agent loop
      case agent_loop(model, history, tools) do
        {:ok, final_history, final_response, tools_used} ->
          {:ok, final_response, %{
            tools_used: tools_used,
            iterations: if(tools_used == [], do: 1, else: 2)
          }}

        {:error, error} ->
          {:error, error}
      end
    end)
  end

  defp agent_loop(model, history, tools) do
    # First LLM call with tools
    {:ok, stream_response} =
      AgentObs.ReqLLM.trace_stream_text(model, history.messages, tools: tools)

    # Extract response
    text = ReqLLM.StreamResponse.text(stream_response)
    tool_calls = ReqLLM.StreamResponse.extract_tool_calls(stream_response)

    if tool_calls == [] do
      # No tools called - return final response
      final_history = Context.append(history, Context.assistant(text))
      {:ok, final_history, text, []}
    else
      # Execute tools and continue
      tools_used = Enum.map(tool_calls, & &1.name)
      assistant_msg = Context.assistant(text, tool_calls: tool_calls)
      history = Context.append(history, assistant_msg)

      # Execute all tool calls
      history =
        Enum.reduce(tool_calls, history, fn tool_call, ctx ->
          execute_and_append_tool(tool_call, tools, ctx)
        end)

      # Second LLM call with tool results
      {:ok, stream_response} =
        AgentObs.ReqLLM.trace_stream_text(model, history.messages)

      final_text = ReqLLM.StreamResponse.text(stream_response)
      final_history = Context.append(history, Context.assistant(final_text))

      {:ok, final_history, final_text, tools_used}
    end
  end

  defp execute_and_append_tool(tool_call, tools, context) do
    tool = Enum.find(tools, & &1.name == tool_call.name)

    case AgentObs.ReqLLM.trace_tool_execution(tool, tool_call) do
      {:ok, result} ->
        tool_msg = Context.tool_result_message(tool.name, tool_call.id, result)
        Context.append(context, tool_msg)

      {:error, error} ->
        error_result = %{error: "Tool failed: #{inspect(error)}"}
        tool_msg = Context.tool_result_message(tool.name, tool_call.id, error_result)
        Context.append(context, tool_msg)
    end
  end

  defp setup_tools do
    [
      Tool.new!(
        name: "calculator",
        description: "Perform calculations",
        parameter_schema: [expression: [type: :string, required: true]],
        callback: fn %{expression: expr} ->
          {result, _} = Code.eval_string(expr)
          {:ok, result}
        end
      )
    ]
  end
end
```

### Pattern 3: Multi-Stage Pipeline

An agent with distinct stages:

```elixir
defmodule MyApp.PipelineAgent do
  def run(query) do
    AgentObs.trace_agent("pipeline_agent", %{input: query}, fn ->
      # Stage 1: Understand query
      {:ok, intent} = understand_intent(query)

      # Stage 2: Gather information
      {:ok, data} = gather_information(intent)

      # Stage 3: Generate response
      {:ok, response} = generate_response(intent, data)

      {:ok, response, %{
        intent: intent.type,
        data_sources: data.sources,
        iterations: 3
      }}
    end)
  end

  defp understand_intent(query) do
    AgentObs.trace_llm("gpt-4o-mini", %{
      input_messages: [
        %{role: "system", content: "Classify the user's intent"},
        %{role: "user", content: query}
      ]
    }, fn ->
      # Fast, cheap model for classification
      response = call_llm(...)
      {:ok, parse_intent(response), llm_metadata(response)}
    end)
  end

  defp gather_information(intent) do
    # Multiple parallel tool calls
    tasks =
      for source <- required_sources(intent) do
        Task.async(fn -> fetch_from_source(source) end)
      end

    results = Task.await_many(tasks)
    {:ok, %{sources: results}}
  end

  defp fetch_from_source(source) do
    AgentObs.trace_tool("fetch_#{source}", %{arguments: %{source: source}}, fn ->
      data = external_api_call(source)
      {:ok, data}
    end)
  end

  defp generate_response(intent, data) do
    AgentObs.trace_llm("gpt-4o", %{
      input_messages: build_final_prompt(intent, data)
    }, fn ->
      # More powerful model for final response
      response = call_llm(...)
      {:ok, response.content, llm_metadata(response)}
    end)
  end
end
```

### Pattern 4: Streaming Agent (ReqLLM)

For real-time streaming responses:

```elixir
defmodule MyApp.StreamingAgent do
  def run_stream(query) do
    AgentObs.trace_agent("streaming_agent", %{input: query}, fn ->
      # Using ReqLLM for automatic instrumentation
      {:ok, stream_response} =
        AgentObs.ReqLLM.trace_stream_text(
          "anthropic:claude-3-5-sonnet",
          [%{role: "user", content: query}],
          tools: get_tools()
        )

      # Stream to user in real-time
      stream_response.stream
      |> Stream.filter(&(&1.type == :content))
      |> Stream.each(&IO.write(&1.text))
      |> Stream.run()

      # Extract metadata automatically
      tool_calls = ReqLLM.StreamResponse.extract_tool_calls(stream_response)
      tokens = ReqLLM.StreamResponse.usage(stream_response)

      # Handle tool calls if any
      if tool_calls != [] do
        handle_tool_calls(tool_calls, stream_response)
      end

      {:ok, "Response streamed", %{
        tool_calls: length(tool_calls),
        tokens: tokens.total
      }}
    end)
  end

  defp handle_tool_calls(tool_calls, previous_response) do
    for tool_call <- tool_calls do
      AgentObs.ReqLLM.trace_tool_execution(tool_call, get_tools(), fn ->
        Tools.execute(tool_call)
      end)
    end
  end
end
```

### Pattern 5: Prompt Templates

For prompt engineering workflows:

```elixir
defmodule MyApp.PromptTemplates do
  def render_and_call(template_name, variables) do
    # Instrument prompt rendering
    {:ok, rendered} =
      AgentObs.trace_prompt(template_name, %{variables: variables}, fn ->
        prompt = Templates.render(template_name, variables)
        {:ok, prompt}
      end)

    # Then call LLM with rendered prompt
    AgentObs.trace_llm("gpt-4o", %{
      input_messages: [%{role: "user", content: rendered}]
    }, fn ->
      response = call_llm(rendered)
      {:ok, response.content, llm_metadata(response)}
    end)
  end
end
```

## Best Practices

### 1. Naming Conventions

Use descriptive, consistent names:

```elixir
# Good
AgentObs.trace_agent("customer_support_agent", ...)
AgentObs.trace_tool("search_knowledge_base", ...)
AgentObs.trace_llm("gpt-4o", ...)  # Use actual model name

# Bad
AgentObs.trace_agent("agent1", ...)
AgentObs.trace_tool("tool", ...)
AgentObs.trace_llm("llm", ...)
```

### 2. Include Rich Metadata

Provide context that helps debugging:

```elixir
# Good - Rich context
AgentObs.trace_agent("support_agent", %{
  input: user_query,
  user_id: user.id,
  session_id: session.id,
  model: "gpt-4o"
}, fn ->
  # ...
  {:ok, response, %{
    tools_used: ["search_kb", "create_ticket"],
    iterations: 3,
    confidence: 0.95,
    fallback_used: false
  }}
end)

# Bad - Minimal context
AgentObs.trace_agent("agent", %{input: query}, fn ->
  {:ok, response}
end)
```

### 3. Track Token Usage

Always include token counts for LLM calls:

```elixir
AgentObs.trace_llm("gpt-4o", %{
  input_messages: messages
}, fn ->
  response = call_openai(messages)

  {:ok, response.message, %{
    output_messages: [response.message],
    tokens: %{
      prompt: response.usage.prompt_tokens,
      completion: response.usage.completion_tokens,
      total: response.usage.total_tokens
    },
    # Optional but useful
    cost: calculate_cost(response.usage, "gpt-4o")
  }}
end)
```

### 4. Error Handling

Let errors propagate naturally - AgentObs will capture them:

```elixir
# Good - Natural error handling
AgentObs.trace_tool("api_call", %{arguments: args}, fn ->
  case HTTPoison.get(url) do
    {:ok, %{status_code: 200, body: body}} ->
      {:ok, Jason.decode!(body)}

    {:ok, %{status_code: status}} ->
      {:error, "API returned #{status}"}

    {:error, reason} ->
      {:error, "HTTP error: #{inspect(reason)}"}
  end
end)

# Bad - Swallowing errors
AgentObs.trace_tool("api_call", %{arguments: args}, fn ->
  try do
    result = HTTPoison.get!(url)
    {:ok, result}
  rescue
    _ -> {:ok, nil}  # Don't do this!
  end
end)
```

### 5. Use Consistent Return Values

Follow the expected return format:

```elixir
# For agents - Include metadata
{:ok, output, metadata}

# For LLM calls - Include messages and tokens
{:ok, message, %{
  output_messages: [message],
  tokens: %{prompt: p, completion: c, total: t}
}}

# For tools - Simple result
{:ok, result}

# For prompts - Rendered text
{:ok, rendered_prompt}

# For errors - Descriptive message
{:error, "Detailed error message"}
```

### 6. Instrument at the Right Level

Don't over-instrument:

```elixir
# Good - Instrument meaningful operations
AgentObs.trace_tool("search_database", %{arguments: %{query: q}}, fn ->
  results = DB.search(q)
  {:ok, results}
end)

# Bad - Too granular
AgentObs.trace_tool("parse_json", %{arguments: %{text: text}}, fn ->
  {:ok, Jason.decode!(text)}
end)
```

### 7. Handle Streaming Properly

When streaming, ensure metadata is still captured:

```elixir
# With ReqLLM (automatic - recommended)
{:ok, stream_response} = AgentObs.ReqLLM.trace_stream_text(model, messages)

# Stream to user in real-time
stream_response.stream
|> Stream.each(&IO.write(&1.text))
|> Stream.run()

# Or collect everything at once
collected = AgentObs.ReqLLM.collect_stream(stream_response)
# Returns: %{text: ..., tokens: ..., tool_calls: ..., finish_reason: ...}

# Manual streaming (only if not using ReqLLM)
AgentObs.trace_llm(model, %{input_messages: messages}, fn ->
  stream = call_llm_stream(messages)

  # Collect stream metadata manually
  {chunks, metadata} = collect_stream_metadata(stream)

  # Return with metadata
  {:ok, chunks, metadata}
end)
```

## Advanced Techniques

### Custom Events

For operations that don't fit standard categories:

```elixir
# Emit custom telemetry events
AgentObs.emit(:cache_hit, %{
  key: cache_key,
  ttl: ttl,
  size: byte_size(value)
})

AgentObs.emit(:rate_limit_triggered, %{
  provider: "openai",
  reset_at: reset_timestamp
})
```

### Nested Agent Calls

Agents can call other agents:

```elixir
defmodule MyApp.MasterAgent do
  def run(task) do
    AgentObs.trace_agent("master_agent", %{input: task}, fn ->
      # Delegate to specialist agents
      results =
        for subtask <- break_down_task(task) do
          SpecialistAgent.run(subtask)  # This creates nested spans!
        end

      {:ok, combine_results(results), %{subtasks: length(results)}}
    end)
  end
end

defmodule MyApp.SpecialistAgent do
  def run(subtask) do
    AgentObs.trace_agent("specialist_agent", %{input: subtask}, fn ->
      # This becomes a child span
      result = process_subtask(subtask)
      {:ok, result}
    end)
  end
end
```

### Conditional Instrumentation

Skip instrumentation in certain scenarios:

```elixir
defmodule MyApp.CachedAgent do
  def run(query) do
    # Check cache first
    case Cache.get(query) do
      {:ok, cached_response} ->
        # Return cached without instrumentation
        {:ok, cached_response}

      :miss ->
        # Only instrument on cache miss
        AgentObs.trace_agent("cached_agent", %{input: query}, fn ->
          response = expensive_operation(query)
          Cache.put(query, response)
          {:ok, response}
        end)
    end
  end
end
```

### Parallel Operations

Instrument parallel operations correctly:

```elixir
defmodule MyApp.ParallelAgent do
  def run(queries) do
    AgentObs.trace_agent("parallel_agent", %{input: queries}, fn ->
      # Each task gets its own span
      tasks =
        for query <- queries do
          Task.async(fn ->
            AgentObs.trace_llm("gpt-4o", %{input_messages: [...]}, fn ->
              call_llm(query)
            end)
          end)
        end

      results = Task.await_many(tasks)
      {:ok, results, %{parallel_calls: length(results)}}
    end)
  end
end
```

## Common Pitfalls

### Pitfall 1: Forgetting Return Values

```elixir
# Bad - Function doesn't return anything
AgentObs.trace_agent("my_agent", %{input: query}, fn ->
  result = process(query)
  # Missing return!
end)

# Good
AgentObs.trace_agent("my_agent", %{input: query}, fn ->
  result = process(query)
  {:ok, result}
end)
```

### Pitfall 2: Incorrect Nesting

```elixir
# Bad - Spans created separately (siblings instead of parent-child)
agent_result = AgentObs.trace_agent("agent", %{input: q}, fn -> {:ok, "done"} end)
llm_result = AgentObs.trace_llm("gpt-4o", %{...}, fn -> {:ok, "response"} end)

# Good - LLM call nested inside agent
AgentObs.trace_agent("agent", %{input: q}, fn ->
  AgentObs.trace_llm("gpt-4o", %{...}, fn ->
    {:ok, "response"}
  end)

  {:ok, "done"}
end)
```

### Pitfall 3: Missing Metadata

```elixir
# Bad - No token information
AgentObs.trace_llm("gpt-4o", %{input_messages: msgs}, fn ->
  response = call_llm(msgs)
  {:ok, response.content}  # Missing tokens!
end)

# Good - Include token metadata
AgentObs.trace_llm("gpt-4o", %{input_messages: msgs}, fn ->
  response = call_llm(msgs)
  {:ok, response.content, %{
    output_messages: [%{role: "assistant", content: response.content}],
    tokens: %{
      prompt: response.usage.prompt_tokens,
      completion: response.usage.completion_tokens,
      total: response.usage.total_tokens
    }
  }}
end)
```

### Pitfall 4: Instrumenting Too Much

```elixir
# Bad - Over-instrumentation creates noise
defp parse_response(text) do
  AgentObs.trace_tool("json_parse", %{arguments: %{text: text}}, fn ->
    {:ok, Jason.decode!(text)}
  end)
end

# Good - Only instrument meaningful operations
defp parse_response(text) do
  Jason.decode!(text)
end
```

### Pitfall 5: Blocking Streams

```elixir
# Bad - Consuming stream blocks until complete
{:ok, stream_response} = AgentObs.ReqLLM.trace_stream_text(model, messages)
all_chunks = Enum.to_list(stream_response.stream)  # Blocks!

# Good - Stream in real-time
{:ok, stream_response} = AgentObs.ReqLLM.trace_stream_text(model, messages)
stream_response.stream
|> Stream.each(&process_chunk/1)
|> Stream.run()
```

## Error Handling in Practice

### Real-World Error Scenarios

Based on the demo scenarios, here are common error handling patterns:

#### Division by Zero

```elixir
defp calculator_callback(%{operation: "divide", operands: [a, b]}) do
  AgentObs.trace_tool("calculator", %{
    arguments: %{operation: "divide", operands: [a, b]}
  }, fn ->
    if b == 0 do
      {:error, "Division by zero"}
    else
      {:ok, a / b}
    end
  end)
end
```

When the tool returns `{:error, reason}`, AgentObs automatically:

1. Marks the span as errored
2. Records the error message in span attributes
3. Allows the error to propagate naturally

#### Invalid Tool Arguments

```elixir
defp execute_tool(tool_call, tools, context) do
  tool = Enum.find(tools, & &1.name == tool_call.name)

  if tool do
    # Execute with instrumentation
    case AgentObs.ReqLLM.trace_tool_execution(tool, tool_call) do
      {:ok, result} ->
        # Success - add result to context
        tool_msg = Context.tool_result_message(tool_call.name, tool_call.id, result)
        Context.append(context, tool_msg)

      {:error, error} ->
        # Error - still add to context so LLM can see what went wrong
        error_result = %{error: "Tool execution failed: #{inspect(error)}"}
        tool_msg = Context.tool_result_message(tool_call.name, tool_call.id, error_result)
        Context.append(context, tool_msg)
    end
  else
    # Tool not found - record this for observability
    IO.puts("⚠️  Tool #{tool_call.name} not found")
    error_result = %{error: "Tool not found: #{tool_call.name}"}
    tool_msg = Context.tool_result_message(tool_call.name, "unknown", error_result)
    Context.append(context, tool_msg)
  end
end
```

#### Mathematical Constraints

```elixir
defp compute("sqrt", [a]) do
  AgentObs.trace_tool("sqrt", %{arguments: %{value: a}}, fn ->
    if a >= 0 do
      {:ok, :math.sqrt(a)}
    else
      {:error, "Cannot take square root of negative number: #{a}"}
    end
  end)
end
```

### Error Observability Benefits

With proper error handling and AgentObs instrumentation:

1. **Errors are traced** - Failed spans appear in Phoenix/Jaeger with error
   status
2. **Error messages are captured** - Full error details in span attributes
3. **Stack traces are preserved** - Exception events include full stacktrace
4. **Agent can recover** - LLM sees tool errors and can retry or provide
   alternative

### Testing Error Scenarios

Test that errors are properly instrumented:

```elixir
test "division by zero is properly traced" do
  Application.put_env(:agent_obs, :enabled, true)

  result = MyAgent.run("Calculate 100 divided by 0")

  # Agent should handle the error gracefully
  assert {:ok, response, metadata} = result
  assert response =~ "cannot divide" or response =~ "error"

  # Check that error was captured (requires test handler)
  Application.put_env(:agent_obs, :enabled, false)
end
```

## Testing with Instrumentation

Disable instrumentation in tests:

```elixir
# config/test.exs
config :agent_obs,
  enabled: false
```

Or test with instrumentation enabled:

```elixir
# In your test
test "agent processes query correctly" do
  # Enable for this test
  Application.put_env(:agent_obs, :enabled, true)

  result = MyAgent.run("test query")

  assert {:ok, response, metadata} = result
  assert metadata.iterations == 1

  # Cleanup
  Application.put_env(:agent_obs, :enabled, false)
end
```

## LangChain and Sagents Integration

For applications using LangChain or Sagents, AgentObs provides higher-level
integration that eliminates manual `trace_llm/3` and `trace_tool/3` calls.

### LangChain: `run/2` (Full Lifecycle)

Wraps `LLMChain.run/2` with an outer LLM span:

```elixir
{:ok, chain} =
  LLMChain.new!(%{llm: model, messages: messages})
  |> LLMChain.add_tools(tools)
  |> AgentObs.LangChain.run(mode: :while_needs_response)
```

In `while_needs_response` mode, each iteration creates a child LLM span nested
under the outer span, giving visibility into multi-turn loops.

### LangChain: `instrument/2` (Direct Instrumentation)

For chains managed by Sagents or your own loop, instrument directly:

```elixir
chain =
  LLMChain.new!(%{llm: model, messages: messages})
  |> LLMChain.add_tools(tools)
  |> AgentObs.LangChain.instrument()
```

Options:

- `:parent_ctx` - OTel context for `Task.async` boundaries
- `:trace_tools` - Enable/disable tool tracing (default: `true`)
- `:metadata` - Extra metadata attached to all spans

### Context Propagation Across Tasks

OTel context is process-local. When spawning tasks, capture and restore it:

```elixir
parent_ctx = OpenTelemetry.Ctx.get_current()

Task.async(fn ->
  chain
  |> AgentObs.LangChain.instrument(parent_ctx: parent_ctx)
  |> LLMChain.run()
end)
```

### Sagents Middleware

Add `AgentObs.Sagents` first in the middleware list:

```elixir
{:ok, agent} = Agent.new(%{
  agent_id: "my-agent",
  model: model,
  middleware: [
    AgentObs.Sagents,
    Sagents.Middleware.TodoList
  ]
})
```

Each iteration of the agent loop emits `[:agent_obs, :llm, :start/stop]` events
with accurate timing. For tool tracing, instrument the chain with
`AgentObs.LangChain.instrument/2`.

See `AgentObs.LangChain` and `AgentObs.Sagents` module docs for full details.

## Next Steps

- **[ReqLLM Integration](req_llm_integration.md)** - Simplified streaming
  instrumentation
- **[LangChain & Sagents Integration](langchain_sagents.md)** - Callback-based
  instrumentation for LangChain and middleware for Sagents
- **[Custom Handlers](custom_handlers.md)** - Building custom observability
  backends
- **[Configuration Guide](configuration.md)** - Advanced configuration options
