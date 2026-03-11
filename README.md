# AgentObs

[![Hex.pm](https://img.shields.io/hexpm/v/agent_obs.svg)](https://hex.pm/packages/agent_obs)
[![Documentation](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/agent_obs)
[![CI](https://github.com/lostbean/agent_obs/workflows/CI/badge.svg)](https://github.com/lostbean/agent_obs/actions)

**An Elixir library for LLM agent observability.**

AgentObs provides a simple, powerful, and idiomatic interface for instrumenting
LLM agentic applications with telemetry events. It supports multiple
observability backends through a pluggable handler architecture.

## Features

- 🎯 **High-level instrumentation helpers** - `trace_agent/3`, `trace_tool/3`,
  `trace_llm/3`, `trace_prompt/3`
- 🤖 **ReqLLM integration helpers (optional)** - Automatic instrumentation for
  ReqLLM with token tracking and streaming support
- 🔌 **Pluggable backend architecture** - Support for multiple observability
  platforms
- 🌟 **OpenInference support** - Full semantic conventions for Arize Phoenix
- 📊 **Rich metadata tracking** - Token usage, costs, tool calls, and more
- 🚀 **Built on OTP** - Supervised handlers with fault tolerance
- 🔗 **Jido integration (optional)** - Zero-code tracing for Jido composer
  workflows
- 🧪 **Backend-agnostic** - Standardized event schema independent of backends

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

## Installation

Add `agent_obs` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:agent_obs, "~> 0.1.0"}
  ]
end
```

## Quick Start

### 1. Configure AgentObs

```elixir
# config/config.exs
config :agent_obs,
  enabled: true,
  handlers: [AgentObs.Handlers.Phoenix]

# config/runtime.exs (for Arize Phoenix)
config :opentelemetry,
  span_processor: :batch,
  resource: [service: [name: "my_llm_agent"]]

config :opentelemetry_exporter,
  otlp_protocol: :http_protobuf,
  otlp_endpoint: System.get_env("ARIZE_PHOENIX_OTLP_ENDPOINT", "http://localhost:6006"),
  otlp_headers: []
# Note: /v1/traces is automatically appended by the exporter
```

### 2. Instrument Your Agent

```elixir
defmodule MyApp.WeatherAgent do
  def get_forecast(city) do
    AgentObs.trace_agent("weather_forecast", %{input: "What's the weather in #{city}?"}, fn ->
      # Call LLM to determine tool to use
      {:ok, tool_call, _metadata} = call_llm_for_planning(city)

      # Execute the tool
      {:ok, weather_data} = AgentObs.trace_tool("get_weather_api", %{
        arguments: %{city: city}
      }, fn ->
        {:ok, %{temp: 72, condition: "sunny"}}
      end)

      # Return final result
      {:ok, "The weather in #{city} is #{weather_data.condition}", %{
        tools_used: ["get_weather_api"],
        iterations: 1
      }}
    end)
  end

  defp call_llm_for_planning(city) do
    AgentObs.trace_llm("gpt-4o", %{
      input_messages: [%{role: "user", content: "Get weather for #{city}"}]
    }, fn ->
      # Simulate LLM API call
      response = call_openai(...)

      {:ok, response, %{
        output_messages: [%{role: "assistant", content: response}],
        tokens: %{prompt: 50, completion: 25, total: 75},
        cost: 0.00012
      }}
    end)
  end
end
```

### 3. View Traces in Arize Phoenix

Start a local Phoenix instance:

```bash
docker run -p 6006:6006 -p 4317:4317 arizephoenix/phoenix:latest
```

Navigate to `http://localhost:6006` to view your traces with:

- Rich chat message visualization
- Token usage and cost tracking
- Tool call inspection
- Nested span relationships

## Handlers

### Phoenix Handler (OpenInference)

Translates events to OpenInference semantic conventions for Arize Phoenix:

```elixir
config :agent_obs,
  handlers: [AgentObs.Handlers.Phoenix]
```

### Generic Handler (Basic OpenTelemetry)

Creates basic OpenTelemetry spans without OpenInference:

```elixir
config :agent_obs,
  handlers: [AgentObs.Handlers.Generic]
```

### Multiple Handlers

Use multiple backends simultaneously:

```elixir
config :agent_obs,
  handlers: [
    AgentObs.Handlers.Phoenix,  # For detailed LLM observability
    AgentObs.Handlers.Generic   # For APM integration
  ]
```

## ReqLLM Integration (Optional)

For applications using [ReqLLM](https://hexdocs.pm/req_llm), AgentObs provides
high-level helpers that automatically instrument LLM calls with full
observability:

```elixir
# Add to your deps
{:req_llm, "~> 1.0.0-rc.7"}

# Non-streaming text generation
{:ok, response} =
  AgentObs.ReqLLM.trace_generate_text(
    "anthropic:claude-3-5-sonnet",
    [%{role: "user", content: "Hello!"}]
  )

text = ReqLLM.Response.text(response)

# Streaming text generation
{:ok, stream_response} =
  AgentObs.ReqLLM.trace_stream_text(
    "anthropic:claude-3-5-sonnet",
    [%{role: "user", content: "Tell me a story"}]
  )

stream_response.stream
|> Stream.filter(&(&1.type == :content))
|> Stream.each(&IO.write(&1.text))
|> Stream.run()

# Structured data generation
schema = [name: [type: :string, required: true], age: [type: :pos_integer]]

{:ok, response} =
  AgentObs.ReqLLM.trace_generate_object(
    "anthropic:claude-3-5-sonnet",
    [%{role: "user", content: "Generate a person"}],
    schema
  )

object = ReqLLM.Response.object(response)
#=> %{name: "Alice", age: 30}
```

**Benefits:**

- Automatic token usage extraction
- Automatic tool call parsing
- Works across all ReqLLM providers (Anthropic, OpenAI, Google, etc.)
- Supports both streaming and non-streaming
- Structured data generation with schema validation
- Bang variants (`!`) for convenience

See the [demo agent](demo/lib/demo/agent.ex) and
[ReqLLM integration guide](guides/req_llm_integration.md) for complete examples.

## Jido Integration (Optional)

For applications using [Jido](https://hexdocs.pm/jido), AgentObs provides
`AgentObs.JidoTracer` — a drop-in `Jido.Observe.Tracer` implementation that
automatically instruments all composer events with OpenTelemetry spans.

```elixir
# Add to your deps
{:jido, "~> 2.0"}

# Configure Jido to use the tracer
config :jido, :observability,
  tracer: AgentObs.JidoTracer
```

That's it. All `[:jido, :composer, :agent|:llm|:tool]` events are automatically
mapped to AgentObs event types and traced with OpenInference semantic conventions.
Parent-child span nesting is preserved, so you get a full trace tree in Phoenix:

```
weather_assistant (agent)
  ├── gpt-4o #1 (llm)
  ├── get_weather (tool)
  └── gpt-4o #2 (llm)
```

See the [Jido integration guide](guides/jido_integration.md) for details on
event mapping, metadata translation, and advanced usage.

## API Reference

### High-Level Instrumentation

- **`trace_agent/3`** - Instruments agent loops or invocations
- **`trace_tool/3`** - Instruments tool calls
- **`trace_llm/3`** - Instruments LLM API calls
- **`trace_prompt/3`** - Instruments prompt template rendering

### ReqLLM Helpers (Optional)

**Text Generation:**

- **`AgentObs.ReqLLM.trace_generate_text/3`** - Non-streaming text generation
- **`AgentObs.ReqLLM.trace_generate_text!/3`** - Non-streaming (bang variant)
- **`AgentObs.ReqLLM.trace_stream_text/3`** - Streaming text generation

**Structured Data Generation:**

- **`AgentObs.ReqLLM.trace_generate_object/4`** - Non-streaming structured data
- **`AgentObs.ReqLLM.trace_generate_object!/4`** - Non-streaming (bang variant)
- **`AgentObs.ReqLLM.trace_stream_object/4`** - Streaming structured data

**Tool Execution:**

- **`AgentObs.ReqLLM.trace_tool_execution/3`** - Instrumented tool execution

**Stream Helpers:**

- **`AgentObs.ReqLLM.collect_stream/1`** - Collect text stream with metadata
- **`AgentObs.ReqLLM.collect_stream_object/1`** - Collect object stream with
  metadata

### Low-Level API

- **`emit/2`** - Emits custom telemetry events
- **`configure/1`** - Runtime configuration updates

See the [full documentation](https://hexdocs.pm/agent_obs) for detailed API
reference and examples.

## Testing

### Running Tests

```bash
# Run all tests (unit tests only, 99 tests)
mix test

# Include integration tests (requires API keys)
mix test --include integration

# Run only integration tests
mix test --only integration
```

### ReqLLM Integration Tests

The ReqLLM module includes comprehensive test coverage with 193 tests:

**Unit Tests (185 tests)** - Run by default, use mocked streams:

- Stream text and object collection
- Tool call extraction and argument parsing
- Token usage extraction
- Function signature validation
- Error handling (malformed JSON, missing data)
- Edge cases (nil values, partial data, multiple fragments)
- All generate_text, generate_object, and stream_object variants

**Integration Tests (8 tests)** - Excluded by default, require real LLM API
calls:

- Real LLM streaming with telemetry verification
- Real non-streaming text generation
- Real structured data generation (objects)
- Real streaming object generation
- Real tool execution with instrumentation
- Full agent loop with streaming and tools
- Bang variants (`!`) with real API calls

To run integration tests, set one of these environment variables:

```bash
export ANTHROPIC_API_KEY=your_key  # Uses claude-3-5-haiku-latest
# OR
export OPENAI_API_KEY=your_key     # Uses gpt-4o-mini
# OR
export GOOGLE_API_KEY=your_key     # Uses gemini-2.0-flash-exp

mix test --include integration
```

If no API key is configured, integration tests gracefully skip without failing.

## Development

### Quick Commands

```bash
# Install dependencies
mix deps.get

# Run pre-commit checks (format, test, credo)
mix precommit

# Run CI checks (format check, test, credo)
mix ci
```

### Individual Commands

```bash
# Run tests
mix test

# Format code
mix format

# Check if code is formatted
mix format --check-formatted

# Run Credo (code quality)
mix credo

# Run Credo in strict mode
mix credo --strict

# Generate documentation
mix docs

# Run Dialyzer (type checking)
mix dialyzer
```

### Pre-commit Hook

For automatic code quality checks before commits, you can run:

```bash
mix precommit
```

This will:

1. Format your code
2. Run all tests
3. Run Credo in strict mode

### CI Pipeline

The `mix ci` command is designed for continuous integration and will:

1. Check that code is properly formatted (fails if not)
2. Run all tests
3. Run Credo in strict mode

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

MIT License - see [LICENSE](LICENSE) file for details.

Copyright (c) 2025 Edgar Gomes

## References

- [OpenInference Specification](https://arize-ai.github.io/openinference/spec/semantic_conventions.html)
- [Arize Phoenix Documentation](https://arize.com/docs/phoenix/)
- [OpenTelemetry Elixir](https://hexdocs.pm/opentelemetry/)
- [Elixir Telemetry](https://hexdocs.pm/telemetry/)
