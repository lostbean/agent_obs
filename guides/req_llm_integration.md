# ReqLLM Integration Guide

AgentObs provides first-class integration with
[ReqLLM](https://hexdocs.pm/req_llm), offering automatic instrumentation for
streaming LLM calls with minimal boilerplate.

## Table of Contents

- [Why ReqLLM Integration?](#why-reqllm-integration)
- [Installation](#installation)
- [Basic Usage](#basic-usage)
- [Complete Agent Example](#complete-agent-example)
- [Advanced Features](#advanced-features)
- [Best Practices](#best-practices)
- [Comparison with Manual Instrumentation](#comparison-with-manual-instrumentation)

## Why ReqLLM Integration?

Manual instrumentation of streaming LLM calls requires:

- Token extraction from provider-specific response formats
- Tool call parsing from streaming chunks
- Stream tee-ing to avoid blocking
- Provider-specific handling (Anthropic, OpenAI, Google, etc.)

**ReqLLM helpers eliminate all of this:**

```elixir
# Manual approach (50+ lines)
AgentObs.trace_llm(model, %{input_messages: messages}, fn ->
  stream = call_provider_api(messages)

  # Manually tee stream to extract metadata
  {replay_stream, metadata_stream} = Stream.split(stream, fn _ -> true end)

  # Manually parse chunks for tool calls
  tool_calls = extract_tool_calls_from_chunks(metadata_stream)

  # Manually extract token usage
  tokens = extract_token_usage(metadata_stream)

  {:ok, replay_stream, %{
    tool_calls: tool_calls,
    tokens: tokens
  }}
end)

# ReqLLM approach (3 lines)
{:ok, stream_response} =
  AgentObs.ReqLLM.trace_stream_text(model, messages, tools: tools)

# Everything extracted automatically!
```

## Installation

Add both dependencies to `mix.exs`:

```elixir
def deps do
  [
    {:agent_obs, "~> 0.1.0"},
    {:req_llm, "~> 1.0.0-rc.7"}
  ]
end
```

ReqLLM is an **optional** dependency. AgentObs works without it, but the
`AgentObs.ReqLLM` module won't be available.

### Configuration

Configure your default LLM model:

```elixir
# config/config.exs
config :req_llm,
  default_model: "anthropic:claude-3-5-sonnet"
```

Or use environment variables for flexibility:

```elixir
# config/runtime.exs
config :req_llm,
  default_model: System.get_env(
    "DEFAULT_MODEL",
    "google:gemini-2.5-flash-lite-preview-09-2025"
  )
```

This allows you to override the model at runtime:

```bash
DEFAULT_MODEL="openai:gpt-4o" iex -S mix
```

**Note:** The demo uses this pattern. Check `demo/lib/demo/agent.ex:23-25` for
the implementation.

## Basic Usage

### Non-Streaming Text Generation

For simple, blocking text generation:

```elixir
# Returns full response with metadata
{:ok, response} =
  AgentObs.ReqLLM.trace_generate_text(
    "anthropic:claude-3-5-sonnet",
    [%{role: "user", content: "Write a haiku about Elixir"}]
  )

# Extract text from response
text = ReqLLM.Response.text(response)
IO.puts(text)

# Access usage metadata
usage = ReqLLM.Response.usage(response)
IO.inspect(usage) # %{input_tokens: 15, output_tokens: 20}

# Bang variant for convenience (raises on error)
text = AgentObs.ReqLLM.trace_generate_text!(
  "anthropic:claude-3-5-sonnet",
  [%{role: "user", content: "Hello!"}]
)
```

### Streaming Text Generation

For real-time streaming:

```elixir
{:ok, stream_response} =
  AgentObs.ReqLLM.trace_stream_text(
    "anthropic:claude-3-5-sonnet",
    [%{role: "user", content: "Write a haiku about Elixir"}]
  )

# Stream output in real-time
stream_response.stream
|> Stream.filter(&(&1.type == :content))
|> Stream.each(&IO.write(&1.text))
|> Stream.run()

# Automatically captured metadata
tokens = ReqLLM.StreamResponse.usage(stream_response)
IO.inspect(tokens) # %{input_tokens: 15, output_tokens: 20}
```

### Structured Data Generation

Generate structured data with schema validation:

```elixir
# Define schema
schema = [
  name: [type: :string, required: true],
  age: [type: :pos_integer, required: true],
  hobbies: [type: {:list, :string}]
]

# Non-streaming structured data
{:ok, response} =
  AgentObs.ReqLLM.trace_generate_object(
    "anthropic:claude-3-5-sonnet",
    [%{role: "user", content: "Generate a person named Alice who likes reading"}],
    schema
  )

object = ReqLLM.Response.object(response)
#=> %{name: "Alice", age: 30, hobbies: ["reading", "writing"]}

# Bang variant
object = AgentObs.ReqLLM.trace_generate_object!(
  "anthropic:claude-3-5-sonnet",
  [%{role: "user", content: "Generate a person"}],
  schema
)
```

### Streaming Structured Data

Stream structured data generation in real-time:

```elixir
schema = [
  title: [type: :string, required: true],
  chapters: [type: {:list, :string}, required: true]
]

{:ok, stream_response} =
  AgentObs.ReqLLM.trace_stream_object(
    "anthropic:claude-3-5-sonnet",
    [%{role: "user", content: "Create a book outline about Elixir"}],
    schema
  )

# Stream chunks as they arrive
stream_response.stream
|> Stream.each(&IO.inspect/1)
|> Stream.run()

# Collect final object with metadata
result = AgentObs.ReqLLM.collect_stream_object(stream_response)
IO.inspect(result.object)
#=> %{title: "Mastering Elixir", chapters: ["Getting Started", "OTP", ...]}
IO.inspect(result.tokens)
#=> %{prompt: 20, completion: 50, total: 70}
```

### With Tools

Define tools using ReqLLM's tool API:

```elixir
tools = [
  ReqLLM.Tool.new!(
    name: "calculator",
    description: "Performs mathematical calculations",
    parameter_schema: [
      expression: [
        type: :string,
        required: true,
        description: "The mathematical expression to evaluate"
      ]
    ],
    callback: fn params ->
      result = evaluate_math(params.expression)
      {:ok, %{result: result}}
    end
  ),

  ReqLLM.Tool.new!(
    name: "search_web",
    description: "Searches the web for information",
    parameter_schema: [
      query: [type: :string, required: true]
    ],
    callback: fn params ->
      results = search_api(params.query)
      {:ok, %{results: results}}
    end
  )
]

# Call LLM with tools
{:ok, stream_response} =
  AgentObs.ReqLLM.trace_stream_text(
    "anthropic:claude-3-5-sonnet",
    [%{role: "user", content: "What is 25 * 17?"}],
    tools: tools
  )

# Extract tool calls (automatically parsed from stream)
tool_calls = ReqLLM.StreamResponse.extract_tool_calls(stream_response)

# Execute tools with instrumentation
for tool_call <- tool_calls do
  tool = Enum.find(tools, & &1.name == tool_call.name)
  {:ok, result} = AgentObs.ReqLLM.trace_tool_execution(tool, tool_call)
  IO.inspect(result)
end
```

## Complete Agent Example

Here's a full agent implementation using ReqLLM helpers:

```elixir
defmodule MyApp.InstrumentedAgent do
  @moduledoc """
  A complete agent example with ReqLLM integration.
  """

  use GenServer

  alias ReqLLM.{Context, Tool}

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def chat(message) do
    GenServer.call(__MODULE__, {:chat, message}, 60_000)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    system_prompt = """
    You are a helpful AI assistant.
    Use the calculator for math and web_search for current information.
    """

    # Allow model to be configured at initialization or use default from config
    model = Keyword.get(
      opts,
      :model,
      Application.get_env(:req_llm, :default_model, "anthropic:claude-3-5-sonnet")
    )

    history = Context.new([Context.system(system_prompt)])
    tools = setup_tools()

    {:ok, %{history: history, tools: tools, model: model}}
  end

  @impl true
  def handle_call({:chat, message}, _from, state) do
    # Instrument the entire agent execution
    result =
      AgentObs.trace_agent("chat_agent", %{input: message}, fn ->
        # Add user message to history
        new_history = Context.append(state.history, Context.user(message))

        # Call LLM with automatic instrumentation
        case stream_with_tools(state.model, new_history, state.tools) do
          {:ok, final_history, response, tools_used} ->
            {:ok, response, %{
              history: final_history,
              tools_used: tools_used,
              iterations: if(tools_used == [], do: 1, else: 2)
            }}

          {:error, error} ->
            {:error, error}
        end
      end)

    case result do
      {:ok, response, %{history: final_history}} ->
        {:reply, {:ok, response}, %{state | history: final_history}}

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  # Private Functions

  defp stream_with_tools(model, history, tools) do
    # First LLM call with automatic instrumentation
    {:ok, stream_response} =
      AgentObs.ReqLLM.trace_stream_text(
        model,
        history.messages,
        tools: tools
      )

    # Stream to console
    chunks =
      stream_response.stream
      |> Enum.map(fn chunk ->
        IO.write(chunk.text)
        chunk
      end)

    # Extract data
    text = chunks |> Enum.filter(&(&1.type == :content)) |> Enum.map_join("", & &1.text)
    tool_calls = ReqLLM.StreamResponse.extract_tool_calls(stream_response)

    # If no tools were called, we're done
    if tool_calls == [] do
      final_history = Context.append(history, Context.assistant(text))
      {:ok, final_history, text, []}
    else
      # Execute tools with instrumentation
      assistant_msg = Context.assistant(text, tool_calls: tool_calls)
      history_with_tool_call = Context.append(history, assistant_msg)

      IO.write("\n")
      tools_used = Enum.map(tool_calls, & &1.name)

      # Execute each tool
      history_with_results =
        Enum.reduce(tool_calls, history_with_tool_call, fn tool_call, ctx ->
          execute_tool(tool_call, tools, ctx)
        end)

      # Second LLM call with tool results
      case stream_final_response(model, history_with_results) do
        {:ok, final_history, final_text} ->
          {:ok, final_history, final_text, tools_used}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  defp execute_tool(tool_call, tools, context) do
    # Find the tool
    tool = Enum.find(tools, & &1.name == tool_call.name)

    # Execute with instrumentation
    {:ok, result} = AgentObs.ReqLLM.trace_tool_execution(tool, tool_call)

    IO.puts("\nTool #{tool_call.name} result: #{inspect(result)}\n")

    # Add result to context
    tool_result_msg = Context.tool_result_message(tool_call.name, tool_call.id, result)
    Context.append(context, tool_result_msg)
  end

  defp stream_final_response(model, history) do
    {:ok, stream_response} =
      AgentObs.ReqLLM.trace_stream_text(model, history.messages)

    # Stream final response
    chunks =
      stream_response.stream
      |> Enum.map(fn chunk ->
        IO.write(chunk.text)
        chunk
      end)

    text = chunks |> Enum.filter(&(&1.type == :content)) |> Enum.map_join("", & &1.text)
    final_history = Context.append(history, Context.assistant(text))

    {:ok, final_history, text}
  end

  defp setup_tools do
    [
      Tool.new!(
        name: "calculator",
        description: "Evaluates mathematical expressions",
        parameter_schema: [
          expression: [type: :string, required: true]
        ],
        callback: fn params ->
          # Simple math evaluation (use a real library in production!)
          result = eval_math(params.expression)
          {:ok, %{result: result}}
        end
      ),

      Tool.new!(
        name: "web_search",
        description: "Searches the web",
        parameter_schema: [
          query: [type: :string, required: true]
        ],
        callback: fn params ->
          results = search_web(params.query)
          {:ok, %{results: results}}
        end
      )
    ]
  end

  # Placeholder implementations
  defp eval_math(expr), do: "42"  # Use Code.eval_string in production with safety
  defp search_web(_query), do: ["Result 1", "Result 2"]
end
```

## Stream Behavior

### Important: Stream Consumption

The `trace_stream_text/3` function internally consumes the stream to extract
metadata (tokens, tool calls), then provides a replay stream. This means:

- The stream is **fully consumed** before `trace_stream_text/3` returns
- The returned stream is replayed from a cached list, not live from the API
- This function **blocks** until the stream completes
- Metadata extraction happens automatically during consumption

For truly non-blocking streaming where you handle metadata manually, use
`ReqLLM.stream_text/3` directly with `AgentObs.trace_llm/3`.

## Advanced Features

### Collecting Stream Metadata

For text streams:

```elixir
{:ok, stream_response} =
  AgentObs.ReqLLM.trace_stream_text(model, messages, tools: tools)

# Collect everything
collected = AgentObs.ReqLLM.collect_stream(stream_response)

# Access collected data
collected.text          # Full response text
collected.tool_calls    # Extracted tool calls with arguments
collected.tokens        # Token usage
collected.finish_reason # Why the stream ended
```

For structured data streams:

```elixir
{:ok, stream_response} =
  AgentObs.ReqLLM.trace_stream_object(model, messages, schema)

# Collect object with metadata
collected = AgentObs.ReqLLM.collect_stream_object(stream_response)

# Access collected data
collected.object        # Complete structured object
collected.tokens        # Token usage
collected.finish_reason # Why the stream ended
```

### Multi-Provider Support

ReqLLM and AgentObs work seamlessly across providers:

```elixir
# Anthropic Claude
{:ok, response} =
  AgentObs.ReqLLM.trace_stream_text(
    "anthropic:claude-3-5-sonnet",
    messages
  )

# OpenAI GPT
{:ok, response} =
  AgentObs.ReqLLM.trace_stream_text(
    "openai:gpt-4o",
    messages
  )

# Google Gemini
{:ok, response} =
  AgentObs.ReqLLM.trace_stream_text(
    "google:gemini-2.0-flash-exp",
    messages
  )

# All automatically instrumented with correct token extraction!
```

### Custom Tool Execution

You can wrap tool execution with custom logic:

```elixir
defp execute_tool_with_retry(tool_call, tools, max_retries \\ 3) do
  tool = Enum.find(tools, & &1.name == tool_call.name)

  AgentObs.ReqLLM.trace_tool_execution(tool, tool_call, fn ->
    # Custom execution with retry logic
    retry_with_backoff(max_retries, fn ->
      Tool.execute(tool, tool_call.arguments)
    end)
  end)
end
```

### Async Tool Execution

Execute multiple tools in parallel:

```elixir
defp execute_tools_parallel(tool_calls, tools) do
  tool_calls
  |> Enum.map(fn tool_call ->
    Task.async(fn ->
      tool = Enum.find(tools, & &1.name == tool_call.name)
      AgentObs.ReqLLM.trace_tool_execution(tool, tool_call)
    end)
  end)
  |> Task.await_many()
end
```

## Best Practices

### 1. Use ReqLLM for All Streaming

```elixir
# Good - Uses ReqLLM helpers
{:ok, stream_response} = AgentObs.ReqLLM.trace_stream_text(model, messages)

# Avoid - Manual streaming instrumentation
AgentObs.trace_llm(model, %{input_messages: messages}, fn ->
  # Manual stream handling...
end)
```

### 2. Always Stream to User

Don't block on stream collection:

```elixir
# Good - Stream in real-time
stream_response.stream
|> Stream.each(&IO.write(&1.text))
|> Stream.run()

# Bad - Blocking collection
all_chunks = Enum.to_list(stream_response.stream)
```

### 3. Handle Tool Calls Properly

Check for tool calls before assuming final response:

```elixir
tool_calls = ReqLLM.StreamResponse.extract_tool_calls(stream_response)

if tool_calls != [] do
  # Execute tools and call LLM again
  execute_tools_and_continue(tool_calls)
else
  # This is the final response
  text = ReqLLM.StreamResponse.text(stream_response)
  {:ok, text}
end
```

### 4. Preserve Conversation History

Use ReqLLM's Context for clean history management:

```elixir
# Initialize with system prompt
history = Context.new([Context.system("You are helpful")])

# Add user message
history = Context.append(history, Context.user("Hello"))

# Add assistant response
history = Context.append(history, Context.assistant("Hi!"))

# Pass full history to next call
{:ok, response} = AgentObs.ReqLLM.trace_stream_text(model, history.messages)
```

## Comparison with Manual Instrumentation

### Manual Approach (Without ReqLLM)

```elixir
# 48 lines of code (from demo before ReqLLM)
defp call_llm_manual(model, messages, tools) do
  AgentObs.trace_llm(model, %{input_messages: messages}, fn ->
    {:ok, stream} = provider_api_call(model, messages, tools)

    # Manually collect chunks for metadata extraction
    chunks = []
    tool_calls = []

    stream
    |> Enum.reduce({chunks, tool_calls}, fn chunk, {chunks_acc, tools_acc} ->
      # Manual tool call extraction
      new_tools = extract_tool_calls_from_chunk(chunk, tools_acc)
      {[chunk | chunks_acc], new_tools}
    end)

    # Manual token extraction
    tokens = extract_tokens_from_chunks(chunks)

    # Reconstruct text
    text = chunks
      |> Enum.reverse()
      |> Enum.filter(&(&1.type == :content))
      |> Enum.map_join("", & &1.text)

    {:ok, text, %{
      output_messages: [%{role: "assistant", content: text}],
      tool_calls: tool_calls,
      tokens: tokens
    }}
  end)
end
```

### ReqLLM Approach

```elixir
# 3 lines of code
defp call_llm_reqllm(model, messages, tools) do
  AgentObs.ReqLLM.trace_stream_text(model, messages, tools: tools)
  # Everything extracted automatically!
end
```

**Code Reduction:** 93% less code (48 lines → 3 lines)

## Troubleshooting

### Stream not appearing in real-time?

Make sure you're not collecting the stream before processing:

```elixir
# Bad
chunks = Enum.to_list(stream_response.stream)

# Good
stream_response.stream |> Stream.run()
```

### Tool calls not detected?

Verify tools are passed in options:

```elixir
# Correct
AgentObs.ReqLLM.trace_stream_text(model, messages, tools: my_tools)

# Wrong - tools ignored
AgentObs.ReqLLM.trace_stream_text(model, messages)
```

### Missing token counts?

Token extraction is automatic. Check if the provider supports usage metadata:

```elixir
tokens = ReqLLM.StreamResponse.usage(stream_response)
# Returns %{input_tokens: ..., output_tokens: ...}
```

## API Summary

### Complete Function Reference

| Function                   | Type          | Returns                    | Use Case                                  |
| -------------------------- | ------------- | -------------------------- | ----------------------------------------- |
| `trace_generate_text/3`    | Non-streaming | `{:ok, response}`          | Simple text generation with full metadata |
| `trace_generate_text!/3`   | Non-streaming | `text` (raises on error)   | Convenience for simple text               |
| `trace_stream_text/3`      | Streaming     | `{:ok, stream_response}`   | Real-time text streaming                  |
| `trace_generate_object/4`  | Non-streaming | `{:ok, response}`          | Structured data with schema               |
| `trace_generate_object!/4` | Non-streaming | `object` (raises on error) | Convenience for objects                   |
| `trace_stream_object/4`    | Streaming     | `{:ok, stream_response}`   | Real-time structured data                 |
| `trace_tool_execution/3`   | Synchronous   | `{:ok, result}`            | Execute tools with instrumentation        |
| `collect_stream/1`         | Helper        | `%{text, tokens, ...}`     | Collect complete text stream              |
| `collect_stream_object/1`  | Helper        | `%{object, tokens, ...}`   | Collect complete object stream            |

### When to Use Each Function

**Use `trace_generate_text/3`** when:

- You need the complete response before proceeding
- You want access to full metadata (finish_reason, etc.)
- Streaming is not necessary

**Use `trace_generate_text!/3`** when:

- You only need the text content
- You want simpler error handling (let it raise)
- Response metadata is not needed

**Use `trace_stream_text/3`** when:

- You want real-time output to users
- Minimizing time-to-first-token is important
- You need to display progress

**Use `trace_generate_object/4`** when:

- You need structured, validated data
- Schema compliance is required
- Streaming is not necessary

**Use `trace_generate_object!/4`** when:

- You only need the object
- You want simpler error handling
- Response metadata is not needed

**Use `trace_stream_object/4`** when:

- You want real-time structured data generation
- You need progressive updates of the object
- Minimizing time-to-first-token is important

## Next Steps

- **[Instrumentation Guide](instrumentation.md)** - General instrumentation
  patterns
- **[Getting Started](getting_started.md)** - Basic setup and first agent
- **[Configuration](configuration.md)** - Advanced configuration options
