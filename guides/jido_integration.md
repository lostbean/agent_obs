# Jido Integration Guide

AgentObs provides a drop-in tracer for [Jido](https://hexdocs.pm/jido) that
automatically instruments composer events with OpenTelemetry spans and
OpenInference semantic conventions.

## Table of Contents

- [Overview](#overview)
- [Installation](#installation)
- [Configuration](#configuration)
- [How It Works](#how-it-works)
- [Event Mapping](#event-mapping)
- [Metadata Translation](#metadata-translation)
- [Viewing Traces](#viewing-traces)
- [Advanced Usage](#advanced-usage)

## Overview

If you're using Jido's composer to orchestrate agent, LLM, and tool calls,
`AgentObs.JidoTracer` bridges those telemetry events into AgentObs. This gives
you full observability in Arize Phoenix (or any OpenTelemetry backend) with zero
manual instrumentation of your Jido workflows.

**Key benefits:**

- Zero-code instrumentation for Jido composer workflows
- Automatic parent-child span nesting
- OpenInference semantic conventions for rich visualization in Phoenix
- Graceful error handling (never crashes your application)

## Installation

Add both dependencies to `mix.exs`:

```elixir
def deps do
  [
    {:agent_obs, "~> 0.1.3"},
    {:jido, "~> 2.0"}
  ]
end
```

`jido` is an **optional** dependency of `agent_obs`. The `AgentObs.JidoTracer`
module is only available when Jido is installed.

## Configuration

Point Jido's observability config at the tracer:

```elixir
# config/config.exs
config :jido, :observability,
  tracer: AgentObs.JidoTracer

# Also configure AgentObs handlers as usual
config :agent_obs,
  enabled: true,
  handlers: [AgentObs.Handlers.Phoenix]
```

Make sure your OpenTelemetry exporter is configured to send spans to your
backend:

```elixir
# config/runtime.exs
config :opentelemetry,
  span_processor: :batch,
  resource: [service: [name: "my_jido_app"]]

config :opentelemetry_exporter,
  otlp_protocol: :http_protobuf,
  otlp_endpoint: System.get_env("ARIZE_PHOENIX_OTLP_ENDPOINT", "http://localhost:6006")
```

That's it. All Jido composer events will now appear as traced spans.

## How It Works

`AgentObs.JidoTracer` implements the `Jido.Observe.Tracer` behaviour, which
Jido calls automatically during composer execution:

1. **`span_start/2`** - Called when a composer event begins. Creates an
   OpenTelemetry span with attributes translated to OpenInference conventions.
2. **`span_stop/2`** - Called when the event completes. Sets result attributes
   and ends the span.
3. **`span_exception/4`** - Called on errors. Records the exception on the span
   and sets error status.

Parent-child relationships are maintained automatically through OpenTelemetry
context propagation, so nested agent > LLM > tool calls appear correctly in
trace visualizers.

## Event Mapping

Jido event prefixes are classified into AgentObs event types:

| Jido Event Prefix                      | AgentObs Type | Span Name Example     |
| -------------------------------------- | ------------- | --------------------- |
| `[:jido, :composer, :agent, ...]`      | `:agent`      | `"weather_assistant"` |
| `[:jido, :composer, :llm, ...]`        | `:llm`        | `"gpt-4o #2"`         |
| `[:jido, :composer, :tool, ...]`       | `:tool`       | `"get_weather"`       |
| `[:jido, :composer, :iteration, ...]`  | `:chain`      | `"iteration 3"`       |
| Any other prefix                       | `:agent`      | `"agent"`             |

## Metadata Translation

The tracer automatically maps Jido metadata fields to AgentObs format:

### Agent Events

| Jido Field       | AgentObs Field | Notes                      |
| ---------------- | -------------- | -------------------------- |
| `:query`         | `:input`       | Falls back to `:input`     |
| `:name`          | `:name`        | Falls back to `:agent_module` |
| `:model`         | `:model`       | Optional                   |
| `:result`        | `:output`      | On stop, falls back to `:output` |

### LLM Events

| Jido Field         | AgentObs Field     | Notes                          |
| ------------------ | ------------------ | ------------------------------ |
| `:model`           | `:model`           | Defaults to `"unknown"`        |
| `:input_messages`  | `:input_messages`  | Preferred                      |
| `:conversation`    | `:input_messages`  | Normalized to `%{role, content}` maps |
| `:iteration`       | `:iteration`       | Appended to span name          |
| `:tokens`          | `:tokens`          | On stop                        |

### Tool Events

| Jido Field    | AgentObs Field | Notes                              |
| ------------- | -------------- | ---------------------------------- |
| `:tool_name`  | `:name`        | Falls back to `:node_name`, `:name` |
| `:arguments`  | `:arguments`   | Falls back to `:params`            |
| `:result`     | `:result`      | On stop, falls back to `:output`   |

## Viewing Traces

Start a local Arize Phoenix instance:

```bash
docker run -p 6006:6006 -p 4317:4317 arizephoenix/phoenix:latest
```

Navigate to `http://localhost:6006` to see your Jido workflows as nested traces:

```
weather_assistant (agent)
  ├── gpt-4o #1 (llm)
  ├── get_weather (tool)
  └── gpt-4o #2 (llm)
```

## Advanced Usage

### Combining with Manual Instrumentation

You can use `AgentObs.JidoTracer` for Jido workflows while using the
`AgentObs.trace_*` helpers for non-Jido code in the same application:

```elixir
def my_workflow(query) do
  # Manual instrumentation for the outer operation
  AgentObs.trace_agent("my_workflow", %{input: query}, fn ->
    # Jido composer is automatically traced via JidoTracer
    {:ok, result} = Jido.Composer.run(my_composer, query)
    {:ok, result}
  end)
end
```

### Error Handling

The tracer is designed to never crash your application. If span creation or
attribute translation fails, a warning is logged and execution continues
normally:

```
[warning] AgentObs.JidoTracer span_start failed: %RuntimeError{message: "..."}
```

## Next Steps

- **[Getting Started](getting_started.md)** - Basic AgentObs setup
- **[Instrumentation Guide](instrumentation.md)** - Manual instrumentation patterns
- **[ReqLLM Integration](req_llm_integration.md)** - ReqLLM auto-instrumentation
- **[Configuration](configuration.md)** - Advanced configuration options
