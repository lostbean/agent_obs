# Custom Handlers Guide

Learn how to build custom observability backend handlers for AgentObs.

## Table of Contents

- [Handler Architecture](#handler-architecture)
- [Creating a Basic Handler](#creating-a-basic-handler)
- [Event Types and Metadata](#event-types-and-metadata)
- [Complete Handler Examples](#complete-handler-examples)
- [Testing Your Handler](#testing-your-handler)
- [Best Practices](#best-practices)

## Handler Architecture

AgentObs uses a pluggable handler architecture where handlers:

1. **Implement the `AgentObs.Handler` behaviour**
2. **Run as GenServers** under AgentObs.Supervisor
3. **Receive telemetry events** via `:telemetry.attach_many/4`
4. **Translate events** to backend-specific formats

### Handler Lifecycle

```
Application Start
       ↓
Supervisor starts handler GenServer
       ↓
Handler.init/1 calls attach/1
       ↓
:telemetry.attach_many registers callbacks
       ↓
Events flow to handle_event/4
       ↓
Application Stop
       ↓
Handler.terminate/2 calls detach/1
```

## Creating a Basic Handler

### Step 1: Define the Module

```elixir
defmodule MyApp.Handlers.CustomHandler do
  @moduledoc """
  A custom handler that logs events to a file.
  """

  use GenServer
  @behaviour AgentObs.Handler

  require Logger

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # AgentObs.Handler callbacks

  @impl AgentObs.Handler
  def attach(config) do
    # Get event prefix from config (defaults to [:agent_obs])
    event_prefix = Map.get(config, :event_prefix, [:agent_obs])

    # Create unique handler ID
    handler_id = {__MODULE__, event_prefix, self()}

    # Define which events to listen to
    events_to_attach = [
      event_prefix ++ [:agent, :start],
      event_prefix ++ [:agent, :stop],
      event_prefix ++ [:agent, :exception],
      event_prefix ++ [:llm, :start],
      event_prefix ++ [:llm, :stop],
      event_prefix ++ [:llm, :exception],
      event_prefix ++ [:tool, :start],
      event_prefix ++ [:tool, :stop],
      event_prefix ++ [:tool, :exception]
    ]

    # Attach to telemetry
    :ok = :telemetry.attach_many(
      handler_id,
      events_to_attach,
      &__MODULE__.handle_event/4,
      config
    )

    Logger.debug("CustomHandler attached to #{inspect(event_prefix)}")

    # Return state
    {:ok, %{handler_id: handler_id, config: config}}
  end

  @impl AgentObs.Handler
  def handle_event(event_name, measurements, metadata, config) do
    # Extract event type and phase
    event_type = get_event_type(event_name)
    phase = get_event_phase(event_name)

    # Route to appropriate handler
    case phase do
      :start -> handle_start(event_type, metadata, config)
      :stop -> handle_stop(event_type, measurements, metadata, config)
      :exception -> handle_exception(event_type, measurements, metadata, config)
    end

    :ok
  rescue
    exception ->
      Logger.error("CustomHandler error: #{inspect(exception)}")
      :ok
  end

  @impl AgentObs.Handler
  def detach(state) do
    :telemetry.detach(state.handler_id)
    Logger.debug("CustomHandler detached")
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

  defp handle_start(event_type, metadata, config) do
    log_file = Map.get(config, :log_file, "agent_obs.log")

    entry = %{
      timestamp: DateTime.utc_now(),
      event: "#{event_type}.start",
      data: metadata
    }

    append_to_log(log_file, entry)
  end

  defp handle_stop(event_type, measurements, metadata, config) do
    log_file = Map.get(config, :log_file, "agent_obs.log")

    entry = %{
      timestamp: DateTime.utc_now(),
      event: "#{event_type}.stop",
      duration_ms: measurements[:duration] / 1_000_000,
      data: metadata
    }

    append_to_log(log_file, entry)
  end

  defp handle_exception(event_type, measurements, metadata, config) do
    log_file = Map.get(config, :log_file, "agent_obs.log")

    entry = %{
      timestamp: DateTime.utc_now(),
      event: "#{event_type}.exception",
      duration_ms: measurements[:duration] / 1_000_000,
      error: %{
        kind: metadata[:kind],
        reason: inspect(metadata[:reason])
      }
    }

    append_to_log(log_file, entry)
  end

  # Utility functions

  defp get_event_type(event_name) do
    # Event name format: [:agent_obs, :llm, :start] or [:demo, :tool, :stop]
    # Extract the event type (second-to-last element)
    event_name
    |> Enum.reverse()
    |> Enum.at(1)
  end

  defp get_event_phase(event_name) do
    # Extract :start, :stop, or :exception (last element)
    List.last(event_name)
  end

  defp append_to_log(file_path, entry) do
    json = Jason.encode!(entry) <> "\n"
    File.write!(file_path, json, [:append])
  end
end
```

### Step 2: Configure the Handler

```elixir
# config/config.exs
config :agent_obs,
  enabled: true,
  handlers: [MyApp.Handlers.CustomHandler]

# Optional: Handler-specific configuration
# Note: Built-in handlers (Phoenix, Generic) don't use this pattern.
# They rely on OpenTelemetry SDK configuration instead.
# This is only needed if your custom handler reads handler-specific config.
config :agent_obs, MyApp.Handlers.CustomHandler,
  log_file: "logs/agent_obs.jsonl"
```

**Handler Configuration Pattern:**

The `config :agent_obs, HandlerModule` pattern is **optional** and only useful
if your custom handler needs handler-specific settings. The built-in Phoenix and
Generic handlers don't use this pattern - they read settings from OpenTelemetry
SDK configuration.

If you want to use this pattern, access it in your handler's `attach/1` callback:

```elixir
@impl AgentObs.Handler
def attach(config) do
  # Gets handler-specific config if present
  handler_config = Application.get_env(:agent_obs, __MODULE__, %{})
  log_file = Map.get(handler_config, :log_file, "agent_obs.log")

  # Or merge with config passed from supervisor
  full_config = Map.merge(config, handler_config)

  # ... rest of attach logic
end
```

### Step 3: Use It!

```elixir
# Your instrumented code works as normal
AgentObs.trace_agent("my_agent", %{input: "test"}, fn ->
  {:ok, "result"}
end)

# Events are now logged to logs/agent_obs.jsonl
```

## Event Types and Metadata

### Agent Events

**Start Event:**

```elixir
event_name: [:agent_obs, :agent, :start]
measurements: %{}
metadata: %{
  name: "agent_name",
  input: "user query",
  model: "gpt-4o"  # optional
}
```

**Stop Event:**

```elixir
event_name: [:agent_obs, :agent, :stop]
measurements: %{duration: 1_500_000_000}  # nanoseconds
metadata: %{
  output: "agent response",
  iterations: 2,
  tools_used: ["tool1", "tool2"]
}
```

**Exception Event:**

```elixir
event_name: [:agent_obs, :agent, :exception]
measurements: %{duration: 500_000_000}
metadata: %{
  kind: :error,
  reason: %RuntimeError{message: "Failed"},
  stacktrace: [...]
}
```

### LLM Events

**Start Event:**

```elixir
metadata: %{
  model: "gpt-4o",
  input_messages: [
    %{role: "user", content: "Hello"}
  ]
}
```

**Stop Event:**

```elixir
metadata: %{
  output_messages: [
    %{role: "assistant", content: "Hi!"}
  ],
  tokens: %{
    prompt: 10,
    completion: 5,
    total: 15
  },
  cost: 0.00015  # optional
}
```

### Tool Events

**Start Event:**

```elixir
metadata: %{
  name: "calculator",
  arguments: %{expression: "2+2"},
  description: "Performs calculations"  # optional
}
```

**Stop Event:**

```elixir
metadata: %{
  result: %{answer: 4}
}
```

### Prompt Events

**Start Event:**

```elixir
metadata: %{
  name: "greeting_template",
  variables: %{name: "Alice"}
}
```

**Stop Event:**

```elixir
metadata: %{
  rendered: "Hello, Alice!"
}
```

## Complete Handler Examples

### Example 1: Metrics Handler

Track metrics with `:telemetry_metrics`:

```elixir
defmodule MyApp.Handlers.Metrics do
  use GenServer
  @behaviour AgentObs.Handler

  @impl AgentObs.Handler
  def attach(config) do
    event_prefix = Map.get(config, :event_prefix, [:agent_obs])
    handler_id = {__MODULE__, event_prefix, self()}

    # Only attach to :stop events for metrics
    events = [
      event_prefix ++ [:agent, :stop],
      event_prefix ++ [:llm, :stop],
      event_prefix ++ [:tool, :stop]
    ]

    :ok = :telemetry.attach_many(handler_id, events, &__MODULE__.handle_event/4, config)
    {:ok, %{handler_id: handler_id}}
  end

  @impl AgentObs.Handler
  def handle_event(event_name, measurements, metadata, _config) do
    event_type = get_event_type(event_name)

    # Emit custom metrics
    :telemetry.execute(
      [:my_app, :agent_obs, :operation],
      %{duration: measurements[:duration]},
      %{type: event_type, name: metadata[:name] || "unknown"}
    )

    # Track token usage for LLM calls
    if event_type == :llm and metadata[:tokens] do
      :telemetry.execute(
        [:my_app, :llm, :tokens],
        %{total: metadata.tokens.total},
        %{model: metadata[:model] || "unknown"}
      )
    end

    :ok
  end

  @impl AgentObs.Handler
  def detach(state), do: :telemetry.detach(state.handler_id)

  @impl GenServer
  def init(opts), do: attach(opts)

  @impl GenServer
  def terminate(_reason, state), do: detach(state)

  defp get_event_type(event_name), do: event_name |> Enum.reverse() |> Enum.at(1)
end
```

### Example 2: Database Logger

Store traces in PostgreSQL:

```elixir
defmodule MyApp.Handlers.DatabaseLogger do
  use GenServer
  @behaviour AgentObs.Handler

  @impl AgentObs.Handler
  def attach(config) do
    event_prefix = Map.get(config, :event_prefix, [:agent_obs])
    handler_id = {__MODULE__, event_prefix, self()}

    events = [
      event_prefix ++ [:agent, :start],
      event_prefix ++ [:agent, :stop],
      event_prefix ++ [:llm, :start],
      event_prefix ++ [:llm, :stop],
      event_prefix ++ [:tool, :start],
      event_prefix ++ [:tool, :stop]
    ]

    :ok = :telemetry.attach_many(handler_id, events, &__MODULE__.handle_event/4, config)
    {:ok, %{handler_id: handler_id, spans: %{}}}
  end

  @impl AgentObs.Handler
  def handle_event(event_name, measurements, metadata, _config) do
    event_type = get_event_type(event_name)
    phase = get_event_phase(event_name)

    case phase do
      :start ->
        # Create database record
        span_id = create_span_record(event_type, metadata)
        # Store span_id in process dictionary for later
        Process.put({__MODULE__, event_type}, span_id)

      :stop ->
        # Update database record
        span_id = Process.get({__MODULE__, event_type})
        if span_id do
          update_span_record(span_id, measurements, metadata)
          Process.delete({__MODULE__, event_type})
        end

      :exception ->
        span_id = Process.get({__MODULE__, event_type})
        if span_id do
          mark_span_errored(span_id, metadata)
          Process.delete({__MODULE__, event_type})
        end
    end

    :ok
  end

  @impl AgentObs.Handler
  def detach(state), do: :telemetry.detach(state.handler_id)

  @impl GenServer
  def init(opts), do: attach(opts)

  @impl GenServer
  def terminate(_reason, state), do: detach(state)

  # Database functions (simplified - use Ecto in production)

  defp create_span_record(event_type, metadata) do
    MyApp.Repo.insert!(%Span{
      event_type: to_string(event_type),
      name: metadata[:name],
      started_at: DateTime.utc_now(),
      metadata: metadata
    }).id
  end

  defp update_span_record(span_id, measurements, metadata) do
    duration_ms = measurements[:duration] / 1_000_000

    MyApp.Repo.get!(Span, span_id)
    |> Ecto.Changeset.change(%{
      ended_at: DateTime.utc_now(),
      duration_ms: duration_ms,
      result_metadata: metadata
    })
    |> MyApp.Repo.update!()
  end

  defp mark_span_errored(span_id, metadata) do
    MyApp.Repo.get!(Span, span_id)
    |> Ecto.Changeset.change(%{
      ended_at: DateTime.utc_now(),
      status: "error",
      error: inspect(metadata[:reason])
    })
    |> MyApp.Repo.update!()
  end

  defp get_event_type(event_name), do: event_name |> Enum.reverse() |> Enum.at(1)
  defp get_event_phase(event_name), do: List.last(event_name)
end
```

### Example 3: Webhook Handler

Send events to external services:

```elixir
defmodule MyApp.Handlers.Webhook do
  use GenServer
  @behaviour AgentObs.Handler

  @impl AgentObs.Handler
  def attach(config) do
    event_prefix = Map.get(config, :event_prefix, [:agent_obs])
    handler_id = {__MODULE__, event_prefix, self()}

    # Only send completed operations
    events = [
      event_prefix ++ [:agent, :stop],
      event_prefix ++ [:agent, :exception]
    ]

    :ok = :telemetry.attach_many(handler_id, events, &__MODULE__.handle_event/4, config)
    {:ok, %{handler_id: handler_id, config: config}}
  end

  @impl AgentObs.Handler
  def handle_event(event_name, measurements, metadata, config) do
    # Send async to avoid blocking
    Task.start(fn ->
      send_webhook(event_name, measurements, metadata, config)
    end)

    :ok
  end

  @impl AgentObs.Handler
  def detach(state), do: :telemetry.detach(state.handler_id)

  @impl GenServer
  def init(opts), do: attach(opts)

  @impl GenServer
  def terminate(_reason, state), do: detach(state)

  defp send_webhook(event_name, measurements, metadata, config) do
    webhook_url = Map.get(config, :webhook_url)

    payload = %{
      event: Enum.join(event_name, "."),
      timestamp: DateTime.utc_now(),
      duration_ms: measurements[:duration] / 1_000_000,
      metadata: metadata
    }

    HTTPoison.post(webhook_url, Jason.encode!(payload), [
      {"Content-Type", "application/json"}
    ])
  end
end
```

## Testing Your Handler

### Unit Testing

```elixir
defmodule MyApp.Handlers.CustomHandlerTest do
  use ExUnit.Case

  alias MyApp.Handlers.CustomHandler

  test "attaches to telemetry events" do
    config = %{event_prefix: [:test]}

    assert {:ok, state} = CustomHandler.attach(config)
    assert state.handler_id == {CustomHandler, [:test], self()}

    # Clean up
    CustomHandler.detach(state)
  end

  test "handles agent start event" do
    config = %{event_prefix: [:test], log_file: "test.log"}
    {:ok, state} = CustomHandler.attach(config)

    # Emit test event
    :telemetry.execute(
      [:test, :agent, :start],
      %{},
      %{name: "test_agent", input: "test"}
    )

    # Verify log file was written
    assert File.exists?("test.log")

    # Clean up
    CustomHandler.detach(state)
    File.rm("test.log")
  end
end
```

### Integration Testing

```elixir
test "handler processes real agent trace" do
  # Configure handler
  Application.put_env(:agent_obs, :enabled, true)
  Application.put_env(:agent_obs, :handlers, [MyApp.Handlers.CustomHandler])

  # Run actual instrumented code
  result = AgentObs.trace_agent("test", %{input: "test"}, fn ->
    {:ok, "output"}
  end)

  # Verify handler processed events
  assert File.exists?("agent_obs.log")
  content = File.read!("agent_obs.log")
  assert content =~ "agent.start"
  assert content =~ "agent.stop"

  # Clean up
  File.rm("agent_obs.log")
end
```

## Best Practices

### 1. Handle Errors Gracefully

```elixir
@impl AgentObs.Handler
def handle_event(event_name, measurements, metadata, config) do
  # Your logic here
  :ok
rescue
  exception ->
    # Log but don't crash
    Logger.error("Handler error: #{inspect(exception)}")
    :ok
end
```

### 2. Use Async for Expensive Operations

```elixir
def handle_event(event_name, measurements, metadata, config) do
  # Don't block the caller
  Task.start(fn ->
    send_to_external_service(event_name, measurements, metadata)
  end)

  :ok
end
```

### 3. Store Minimal State

```elixir
# Good - minimal state
def init(opts) do
  {:ok, state} = attach(opts)
  {:ok, state}
end

# Bad - storing all events in memory
def init(opts) do
  {:ok, state} = attach(opts)
  {:ok, Map.put(state, :events, [])}  # Memory leak!
end
```

### 4. Clean Up Resources

```elixir
@impl GenServer
def terminate(_reason, state) do
  # Always detach from telemetry
  detach(state)

  # Close any open connections
  close_database_connection(state)

  # Flush any pending writes
  flush_buffer(state)
end
```

### 5. Use Configuration

```elixir
# Allow configuration
config :agent_obs, MyApp.Handlers.CustomHandler,
  batch_size: 100,
  flush_interval: 5000,
  max_retries: 3

# Access in handler
def handle_event(event_name, measurements, metadata, config) do
  batch_size = Map.get(config, :batch_size, 100)
  # Use configuration
end
```

## Next Steps

- **[Getting Started](getting_started.md)** - Set up AgentObs
- **[Instrumentation Guide](instrumentation.md)** - Instrument your code
- **[Configuration](configuration.md)** - Configure AgentObs and handlers

For more examples, see the built-in handlers:

- `AgentObs.Handlers.Phoenix` - OpenInference/Arize Phoenix
- `AgentObs.Handlers.Generic` - Generic OpenTelemetry
