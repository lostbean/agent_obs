# Jaeger Integration for AgentObs

## Overview

AgentObs now supports sending traces to **Jaeger** via the Generic OpenTelemetry handler. This provides standard distributed tracing capabilities alongside the rich OpenInference observability offered by the Phoenix handler.

## Key Differences: Phoenix vs Jaeger

### Phoenix Handler (OpenInference)
- **Purpose:** LLM-specific observability with rich semantic conventions
- **Span Types:** `AGENT`, `LLM`, `TOOL`, `CHAIN` (OpenInference kinds)
- **Message Display:** Flattened message structures shown as conversations
- **Attributes:** Highly detailed with token counts, costs, tool calls
- **Best For:** Debugging LLM behavior, analyzing costs, evaluating agent performance

### Generic Handler (Standard OpenTelemetry)
- **Purpose:** General-purpose distributed tracing for APM tools
- **Span Types:** Standard OpenTelemetry span kinds
- **Message Display:** JSON-encoded attributes
- **Attributes:** Simplified key-value pairs
- **Best For:** Performance analysis, latency debugging, service dependency mapping

## What You See in Each UI

### Jaeger UI Shows:
- ✅ **Trace timeline** - Visual hierarchy of spans
- ✅ **Duration metrics** - Precise timing for each operation
- ✅ **Parent-child relationships** - Nested span structure
- ✅ **Basic attributes** - Key-value pairs (expandable)
- ✅ **Service dependencies** - Call flow between services
- ❌ **No rich LLM context** - Messages are JSON strings
- ❌ **No cost tracking** - Token/cost data in attributes only

### Phoenix UI Shows:
- ✅ **Chat interface** - Messages rendered as conversation
- ✅ **Token tracking** - Prominent display of usage
- ✅ **Cost analysis** - Per-call cost breakdown
- ✅ **Tool call details** - Function names and arguments highlighted
- ✅ **OpenInference semantics** - LLM-optimized display
- ✅ **Trace timeline** - Also shows timing (like Jaeger)

## How It Works

Both handlers receive the **same telemetry events** from AgentObs instrumentation:
```elixir
AgentObs.trace_agent("my_agent", %{input: "query"}, fn ->
  AgentObs.trace_llm("gpt-4o", %{input_messages: [...]}, fn ->
    # LLM call
  end)
end)
```

But they translate these events differently:

**Phoenix Handler:**
- Adds `openinference.span.kind = "AGENT"`
- Flattens messages: `llm.input_messages.0.message.role = "user"`
- Adds `llm.token_count.prompt`, `llm.token_count.completion`, `llm.cost.total`

**Generic Handler:**
- Adds `agent.name = "my_agent"`
- Adds `llm.request = "{json of all metadata}"`
- Adds `llm.model = "gpt-4o"`
- Adds `duration_ms` from measurements

## Running Demos with Different Backends

### Test with Phoenix (OpenInference)
```bash
cd demo
./scripts/run_demo_phoenix.sh
# View at: http://localhost:6006
```

### Test with Jaeger (Generic OTel)
```bash
cd demo
./scripts/run_demo_jaeger.sh
# View at: http://localhost:16686
```

### Switch Backends Manually
```bash
# Phoenix
OTLP_BACKEND=phoenix mix run -e "Demo.run_all()"

# Jaeger
OTLP_BACKEND=jaeger mix run -e "Demo.run_all()"
```

## Viewing Traces in Jaeger

1. **Navigate to Jaeger UI:** http://localhost:16686
2. **Select Service:** `agent_obs_demo`
3. **Click "Find Traces"**
4. **Click on a trace** to see the timeline
5. **Click on individual spans** to see attributes

### What to Look For:
- **Span hierarchy** - Agent spans containing LLM/tool spans
- **Duration breakdown** - Where time is spent
- **Attributes panel** - Click "Tags" to see all metadata
  - `agent.name` - The agent operation name
  - `llm.model` - Model used
  - `llm.request` - Full request metadata (JSON)
  - `duration_ms` - Operation duration
  - `output.value` - Operation result

## Architecture

```
┌─────────────────────────────────┐
│   AgentObs Instrumentation      │
│   (trace_agent, trace_llm, etc.) │
└────────────┬────────────────────┘
             │ :telemetry events
             │
      ┌──────┴───────┐
      │              │
      ▼              ▼
┌──────────┐   ┌──────────┐
│ Phoenix  │   │ Generic  │
│ Handler  │   │ Handler  │
└────┬─────┘   └────┬─────┘
     │              │
     │ OpenInference│ Standard OTel
     │              │
     ▼              ▼
┌─────────────────────────────────┐
│   OpenTelemetry SDK              │
│   (Configured OTLP Exporter)     │
└────────────┬────────────────────┘
             │
        ┌────┴─────┐
        │          │
        ▼          ▼
   ┌────────┐  ┌────────┐
   │Phoenix │  │Jaeger  │
   │:6006   │  │:16686  │
   └────────┘  └────────┘
```

**Important:** The OpenTelemetry SDK can only export to **one endpoint** at a time (configured in `config/runtime.exs`). The `OTLP_BACKEND` environment variable determines which endpoint to use.

## Troubleshooting

### No Traces in Jaeger

1. **Check services are running:**
   ```bash
   curl http://localhost:16686  # Should return HTML
   curl http://localhost:4318/v1/traces -X POST  # Should return 200
   ```

2. **Verify backend configuration:**
   ```bash
   OTLP_BACKEND=jaeger mix run -e "IO.inspect(Application.get_env(:opentelemetry_exporter, :otlp_endpoint))"
   # Should show: "http://localhost:4318"
   ```

   **Important:** The endpoint should be the BASE URL without `/v1/traces`. The OpenTelemetry Elixir library automatically appends the path. If you see traces failing to appear, verify your `.env` file has:
   ```bash
   JAEGER_OTLP_ENDPOINT=http://localhost:4318  # CORRECT
   # NOT: http://localhost:4318/v1/traces      # WRONG - causes double path
   ```

3. **Check handler is attached:**
   ```bash
   OTLP_BACKEND=jaeger mix run -e "IO.inspect(Application.get_env(:agent_obs, :handlers))"
   # Should show: [AgentObs.Handlers.Generic]
   ```

4. **Wait for batch export:**
   Traces are exported in batches every 5 seconds. After running a demo, wait 6-10 seconds before checking Jaeger.

### Spans Not Showing Properly

- **Issue:** Parent-child relationships broken
- **Cause:** Context not properly managed in handler
- **Fix:** The Generic handler was updated to properly manage OpenTelemetry context (similar to Phoenix handler). Make sure you're using the latest version.

### Attributes Missing

- Jaeger displays all attributes, but you need to **expand the span** to see them
- Click on a span in the trace view
- Look for the "Tags" section
- Some attributes are JSON-encoded (this is intentional for the Generic handler)

## Production Considerations

### Single vs Dual Backend

**Current Setup** (Switch between backends):
- Pros: Simple, no additional infrastructure
- Cons: Must choose one backend per run
- Use when: Testing or you only need one observability platform

**OpenTelemetry Collector** (True dual-backend):
- Pros: Send to both simultaneously, can add more backends later
- Cons: Requires running OTel Collector service
- Use when: Production deployment with multiple observability tools

### Example OTel Collector Setup

```yaml
# docker-compose.yml
services:
  otel-collector:
    image: otel/opentelemetry-collector:latest
    command: ["--config=/etc/otel-collector-config.yaml"]
    volumes:
      - ./otel-collector-config.yaml:/etc/otel-collector-config.yaml
    ports:
      - "4318:4318"  # OTLP HTTP receiver

# otel-collector-config.yaml
receivers:
  otlp:
    protocols:
      http:
        endpoint: 0.0.0.0:4318

exporters:
  otlp/phoenix:
    endpoint: phoenix:6006
    tls:
      insecure: true
  otlp/jaeger:
    endpoint: jaeger:4317
    tls:
      insecure: true

service:
  pipelines:
    traces:
      receivers: [otlp]
      exporters: [otlp/phoenix, otlp/jaeger]
```

Then configure AgentObs to send to the collector:
```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
```

## Next Steps

1. ✅ **Test both backends** - Run demos with Phoenix and Jaeger
2. ✅ **Compare trace views** - See how the same trace appears differently
3. 📝 **Choose your strategy** - Single backend or OTel Collector
4. 🚀 **Deploy to production** - Configure for your observability platform

## Related Documentation

- [AgentObs README](../README.md)
- [Demo README](README.md)
- [Jaeger Documentation](https://www.jaegertracing.io/docs/)
- [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/)
- [OpenInference Specification](https://arize-ai.github.io/openinference/spec/semantic_conventions.html)
