# AgentObs

**A production-grade Elixir library for LLM agent observability.**

AgentObs provides a simple, powerful, and idiomatic interface for instrumenting LLM agentic applications with telemetry events. It supports multiple observability backends through a pluggable handler architecture.

## Features

- 🎯 **High-level instrumentation helpers** - `trace_agent/3`, `trace_tool/3`, `trace_llm/3`, `trace_prompt/3`
- 🔌 **Pluggable backend architecture** - Support for multiple observability platforms
- 🌟 **OpenInference support** - Full semantic conventions for Arize Phoenix
- 📊 **Rich metadata tracking** - Token usage, costs, tool calls, and more
- 🚀 **Built on OTP** - Supervised handlers with fault tolerance
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
  otlp_endpoint: System.get_env("ARIZE_PHOENIX_OTLP_ENDPOINT", "http://localhost:6006/v1/traces"),
  otlp_headers: []
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

## API Reference

### High-Level Instrumentation

- **`trace_agent/3`** - Instruments agent loops or invocations
- **`trace_tool/3`** - Instruments tool calls
- **`trace_llm/3`** - Instruments LLM API calls
- **`trace_prompt/3`** - Instruments prompt template rendering

### Low-Level API

- **`emit/2`** - Emits custom telemetry events
- **`configure/1`** - Runtime configuration updates

See the [full documentation](https://hexdocs.pm/agent_obs) for detailed API reference and examples.

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

Copyright 2025

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

## References

- [OpenInference Specification](https://arize-ai.github.io/openinference/spec/semantic_conventions.html)
- [Arize Phoenix Documentation](https://arize.com/docs/phoenix/)
- [OpenTelemetry Elixir](https://hexdocs.pm/opentelemetry/)
- [Elixir Telemetry](https://hexdocs.pm/telemetry/)

