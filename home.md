# AgentObs

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
- 🧪 **Backend-agnostic** - Standardized event schema independent of backends

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

```elixir
# 1. Configure AgentObs in config/config.exs
config :agent_obs,
  enabled: true,
  handlers: [AgentObs.Handlers.Phoenix]

# 2. Instrument your agent
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

## ReqLLM Integration (Optional)

For applications using [ReqLLM](https://hexdocs.pm/req_llm), AgentObs provides
high-level helpers that automatically instrument LLM calls. ReqLLM integration
is available when `req_llm` is added as a dependency:

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

See the [ReqLLM Integration guide](guides/req_llm_integration.md) for complete
examples.

## Guides

- [Getting Started](guides/getting_started.md) - Detailed setup and
  configuration
- [Configuration](guides/configuration.md) - Configure handlers and backends
- [Instrumentation](guides/instrumentation.md) - Learn about the instrumentation
  API
- [ReqLLM Integration](guides/req_llm_integration.md) - Complete ReqLLM
  integration guide
- [Custom Handlers](guides/custom_handlers.md) - Build your own observability
  backend

## API Reference

### High-Level Instrumentation

- `AgentObs.trace_agent/3` - Instruments agent loops or invocations
- `AgentObs.trace_tool/3` - Instruments tool calls
- `AgentObs.trace_llm/3` - Instruments LLM API calls
- `AgentObs.trace_prompt/3` - Instruments prompt template rendering

### ReqLLM Helpers (Optional)

**Text Generation:**

- `AgentObs.ReqLLM.trace_generate_text/3` - Non-streaming text generation
- `AgentObs.ReqLLM.trace_generate_text!/3` - Non-streaming (bang variant)
- `AgentObs.ReqLLM.trace_stream_text/3` - Streaming text generation

**Structured Data Generation:**

- `AgentObs.ReqLLM.trace_generate_object/4` - Non-streaming structured data
- `AgentObs.ReqLLM.trace_generate_object!/4` - Non-streaming (bang variant)
- `AgentObs.ReqLLM.trace_stream_object/4` - Streaming structured data

**Tool Execution:**

- `AgentObs.ReqLLM.trace_tool_execution/3` - Instrumented tool execution

**Stream Helpers:**

- `AgentObs.ReqLLM.collect_stream/1` - Collect text stream with metadata
- `AgentObs.ReqLLM.collect_stream_object/1` - Collect object stream with
  metadata

### Low-Level API

- `AgentObs.emit/2` - Emits custom telemetry events
- `AgentObs.configure/1` - Runtime configuration updates

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

## License

MIT License - see [LICENSE](LICENSE) file for details.
