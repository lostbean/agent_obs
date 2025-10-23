# Configuration Guide

This guide covers all configuration options for AgentObs, from basic setup to
advanced production configurations.

## Table of Contents

- [Application Configuration](#application-configuration)
- [OpenTelemetry Configuration](#opentelemetry-configuration)
- [Handler Configuration](#handler-configuration)
- [Environment-Specific Configuration](#environment-specific-configuration)
- [Production Best Practices](#production-best-practices)

## Application Configuration

### Basic Configuration

In `config/config.exs`:

```elixir
config :agent_obs,
  # Enable/disable AgentObs globally
  enabled: true,

  # List of handler modules to use
  handlers: [AgentObs.Handlers.Phoenix]
```

### Disabling AgentObs

To completely disable instrumentation (useful for testing or specific
environments):

```elixir
# config/test.exs
config :agent_obs,
  enabled: false,
  handlers: []
```

When disabled, all `trace_*` functions become no-ops with minimal overhead.

### Multiple Handlers

Use multiple backends simultaneously:

```elixir
config :agent_obs,
  enabled: true,
  handlers: [
    AgentObs.Handlers.Phoenix,  # For LLM-specific observability
    AgentObs.Handlers.Generic   # For generic APM integration
  ]
```

Each handler processes events independently, allowing you to send traces to
multiple destinations.

## OpenTelemetry Configuration

AgentObs builds on top of OpenTelemetry, so you'll need to configure the OTel
SDK.

### Span Processor

The span processor determines how spans are exported:

```elixir
config :opentelemetry,
  # Batch processor (recommended for production)
  span_processor: :batch
```

**Options:**

- `:batch` - Buffers spans and exports in batches (recommended)
- `:simple` - Exports each span immediately (useful for testing)

### Batch Processor Configuration

Fine-tune batch export behavior:

```elixir
config :opentelemetry,
  span_processor: :batch,
  processors: [
    otel_batch_processor: %{
      # Maximum queue size (default: 2048)
      max_queue_size: 2048,

      # Time between exports in milliseconds (default: 5000)
      scheduled_delay_ms: 5000,

      # Maximum batch size (default: 512)
      exporter_timeout_ms: 30000,

      # Maximum spans per batch (default: 512)
      max_export_batch_size: 512
    }
  ]
```

### Resource Attributes

Identify your service with resource attributes:

```elixir
config :opentelemetry,
  resource: [
    service: [
      # Service name (appears in UI)
      name: "my_llm_agent",

      # Service version
      version: "1.0.0",

      # Deployment environment
      namespace: "production"
    ]
  ]
```

You can add custom resource attributes:

```elixir
config :opentelemetry,
  resource: [
    service: [name: "my_agent"],

    # Custom attributes
    "deployment.environment": System.get_env("ENV", "development"),
    "k8s.pod.name": System.get_env("POD_NAME"),
    "git.commit": System.get_env("GIT_SHA")
  ]
```

### Exporter Configuration

Configure how traces are exported:

```elixir
config :opentelemetry_exporter,
  # Protocol: :grpc or :http_protobuf
  otlp_protocol: :http_protobuf,

  # Endpoint URL - for HTTP protocol, do not include /v1/traces
  # (the exporter automatically appends it)
  otlp_endpoint: "http://localhost:6006",

  # Optional headers (e.g., for authentication)
  otlp_headers: [],

  # Compression: :gzip or :none
  otlp_compression: :gzip
```

## Handler Configuration

### Phoenix Handler

The Phoenix handler translates AgentObs events to OpenTelemetry spans with
OpenInference semantic conventions. It relies entirely on the OpenTelemetry SDK
configuration - no handler-specific configuration is needed.

```elixir
# AgentObs config - just enable the handler
config :agent_obs,
  enabled: true,
  handlers: [AgentObs.Handlers.Phoenix]

# OpenTelemetry SDK config - this is where Phoenix gets its settings
config :opentelemetry_exporter,
  otlp_protocol: :http_protobuf,
  otlp_endpoint: System.get_env(
    "ARIZE_PHOENIX_OTLP_ENDPOINT",
    "http://localhost:6006"
  ),
  otlp_headers: []
```

**Important:** The Phoenix handler does **not** use handler-specific configuration
like `config :agent_obs, AgentObs.Handlers.Phoenix`. All endpoint and authentication
settings come from the OpenTelemetry SDK configuration above.

#### Cloud Arize Phoenix

For Arize Phoenix cloud:

```elixir
config :opentelemetry_exporter,
  otlp_endpoint: System.fetch_env!("ARIZE_PHOENIX_OTLP_ENDPOINT"),
  otlp_headers: [
    {"authorization", "Bearer #{System.fetch_env!("ARIZE_PHOENIX_API_KEY")}"}
  ]
```

### Generic Handler

The Generic handler translates AgentObs events to standard OpenTelemetry spans
(without OpenInference attributes), suitable for Jaeger, Zipkin, or other
standard OTLP-compatible backends.

```elixir
# AgentObs config - just enable the handler
config :agent_obs,
  enabled: true,
  handlers: [AgentObs.Handlers.Generic]

# OpenTelemetry SDK config - this is where Generic gets its settings
config :opentelemetry_exporter,
  otlp_protocol: :http_protobuf,
  otlp_endpoint: System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318")
```

**Important:** Like the Phoenix handler, the Generic handler does **not** use
handler-specific configuration. All settings come from the OpenTelemetry SDK
configuration above.

### Custom Event Prefix

Customize the telemetry event prefix (advanced):

```elixir
config :agent_obs,
  event_prefix: [:my_app, :observability]
```

This changes events from `[:agent_obs, :agent, :start]` to
`[:my_app, :observability, :agent, :start]`.

**Note:** The event_prefix is configured at the application level, not per-handler.

## Environment-Specific Configuration

### Development

Optimize for developer experience:

```elixir
# config/dev.exs
config :agent_obs,
  enabled: true,
  handlers: [AgentObs.Handlers.Phoenix]

config :opentelemetry,
  span_processor: :batch,
  resource: [service: [name: "my_agent_dev"]]

config :opentelemetry_exporter,
  otlp_endpoint: "http://localhost:6006"

# Enable debug logging
config :logger, level: :debug
```

### Test

Disable for faster tests:

```elixir
# config/test.exs
config :agent_obs,
  enabled: false,
  handlers: []

config :opentelemetry,
  span_processor: :simple

# Quiet logs
config :logger, level: :warning
```

### Production

Optimize for performance and reliability:

```elixir
# config/runtime.exs
config :agent_obs,
  enabled: System.get_env("OTEL_ENABLED", "true") == "true",
  handlers: parse_handlers(System.get_env("OTEL_HANDLERS"))

config :opentelemetry,
  # Batch processor for efficiency
  span_processor: :batch,

  resource: [
    service: [
      name: System.fetch_env!("OTEL_SERVICE_NAME"),
      version: System.get_env("APP_VERSION", "unknown"),
      namespace: System.get_env("ENV", "production")
    ],
    "deployment.environment": System.get_env("ENV", "production"),
    "k8s.pod.name": System.get_env("POD_NAME"),
    "k8s.namespace": System.get_env("K8S_NAMESPACE")
  ]

config :opentelemetry_exporter,
  otlp_protocol: :http_protobuf,
  otlp_endpoint: System.fetch_env!("OTEL_EXPORTER_OTLP_ENDPOINT"),
  otlp_headers: parse_headers(System.get_env("OTEL_EXPORTER_OTLP_HEADERS")),
  otlp_compression: :gzip

# Helper functions
defp parse_handlers(nil), do: [AgentObs.Handlers.Phoenix]
defp parse_handlers(handlers_string) do
  handlers_string
  |> String.split(",")
  |> Enum.map(&String.to_existing_atom/1)
end

defp parse_headers(nil), do: []
defp parse_headers(headers_string) do
  headers_string
  |> String.split(",")
  |> Enum.map(fn header ->
    [key, value] = String.split(header, "=", parts: 2)
    {String.trim(key), String.trim(value)}
  end)
end
```

## Production Best Practices

### 1. Use Environment Variables

Store sensitive configuration in environment variables:

```elixir
# Good
otlp_endpoint: System.fetch_env!("ARIZE_PHOENIX_OTLP_ENDPOINT")

# Bad - hardcoded and includes /v1/traces (which gets auto-appended)
otlp_endpoint: "https://api.arize.com/v1/traces"
```

### 2. Enable Compression

Reduce network traffic in production:

```elixir
config :opentelemetry_exporter,
  otlp_compression: :gzip
```

### 3. Use Batch Processor

Always use batch processor in production:

```elixir
config :opentelemetry,
  span_processor: :batch
```

### 4. Set Resource Attributes

Help identify traces in multi-service deployments:

```elixir
config :opentelemetry,
  resource: [
    service: [
      name: System.fetch_env!("OTEL_SERVICE_NAME"),
      version: System.get_env("APP_VERSION"),
      namespace: System.get_env("K8S_NAMESPACE")
    ]
  ]
```

### 5. Handle Exporter Failures Gracefully

OpenTelemetry handles exporter failures automatically, but you can monitor them:

```elixir
# The OTel SDK will log warnings but continue operation
# Your application won't crash if the exporter fails
```

### 6. Sampling (Future)

For very high-volume applications, consider implementing sampling:

```elixir
# Not yet implemented in AgentObs, but planned for v0.2.0
config :opentelemetry,
  sampler: {:parent_based, %{root: {:trace_id_ratio_based, 0.1}}}
```

This would sample 10% of traces.

### 7. Security Considerations

**API Keys:**

- Never commit API keys to version control
- Use environment variables or secret management systems
- Rotate keys regularly

**Network Security:**

- Use HTTPS endpoints in production
- Consider TLS client certificates for authentication
- Use private networks when possible

**Data Privacy:**

- Be mindful of PII in trace data
- Consider sanitizing sensitive fields
- Review compliance requirements (GDPR, etc.)

## Configuration Validation

Validate your configuration on startup:

```elixir
defmodule MyApp.Application do
  def start(_type, _args) do
    # Validate OTel configuration
    validate_otel_config!()

    # ... rest of your supervision tree
  end

  defp validate_otel_config! do
    unless Application.get_env(:opentelemetry_exporter, :otlp_endpoint) do
      raise "Missing OpenTelemetry exporter endpoint! Set OTEL_EXPORTER_OTLP_ENDPOINT"
    end

    if Application.get_env(:agent_obs, :enabled) do
      handlers = Application.get_env(:agent_obs, :handlers, [])
      if Enum.empty?(handlers) do
        Logger.warning("AgentObs enabled but no handlers configured")
      end
    end
  end
end
```

## Runtime Configuration

Update configuration at runtime:

```elixir
# Temporarily disable instrumentation
AgentObs.configure(enabled: false)

# Re-enable
AgentObs.configure(enabled: true)
```

Note: Runtime configuration only affects the enabled/disabled state. Handler
configuration requires application restart.

## Troubleshooting

### Configuration not taking effect?

1. Check which config file is being used:

   ```bash
   MIX_ENV=prod mix run -e "IO.inspect(Application.get_all_env(:agent_obs))"
   ```

2. Verify runtime.exs is loaded:

   ```elixir
   # Runtime config overrides compile-time config
   # Make sure your changes are in the right file
   ```

3. Restart your application:
   ```bash
   # Configuration changes require restart
   mix phx.server
   ```

### Traces not appearing?

Check exporter connectivity:

```bash
# Test Phoenix endpoint (note: Phoenix UI is on port 6006, OTLP is same port)
curl -v http://localhost:6006

# For Jaeger
curl -v http://localhost:4318

# Check logs for errors
grep -i otel mix.log 2>/dev/null || tail -f log/dev.log 2>/dev/null | grep -i otel
```

### High memory usage?

Reduce batch size:

```elixir
config :opentelemetry,
  processors: [
    otel_batch_processor: %{
      max_queue_size: 1024,  # Reduce from 2048
      max_export_batch_size: 256  # Reduce from 512
    }
  ]
```

### Custom event_prefix not working?

If you've configured a custom event prefix but traces aren't appearing:

```elixir
# config/config.exs
config :agent_obs,
  event_prefix: [:my_app, :ai]
```

**Check:**

1. **Handlers must receive the same prefix:**

   Handlers are started by the supervisor with the event_prefix from config.
   Verify handlers are attaching to the correct prefix:

   ```elixir
   # In iex
   :telemetry.list_handlers(:my_app)
   # Should show your handlers attached to [:my_app, :ai, :agent, :start], etc.
   ```

2. **Event prefix is application-wide:**

   You can't use different prefixes for different parts of your app. All
   `trace_*` calls use the same prefix configured in `:agent_obs` config.

3. **Restart required:**

   Event prefix changes require application restart:

   ```bash
   # Stop and restart your application
   mix phx.server
   # or
   iex -S mix
   ```

4. **Demo uses custom prefix:**

   If you're running the demo, note it uses `event_prefix: [:demo]` by default.
   Check `demo/config/config.exs` if events appear under unexpected prefix.

## Next Steps

- **[Instrumentation Guide](instrumentation.md)** - Learn how to instrument your
  code
- **[ReqLLM Integration](req_llm_integration.md)** - Simplified streaming
  instrumentation
- **[Custom Handlers](custom_handlers.md)** - Build your own backend handlers
