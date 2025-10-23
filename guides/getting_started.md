# Getting Started with AgentObs

This guide will walk you through setting up AgentObs in your Elixir application
and instrumenting your first LLM agent.

## Prerequisites

- Elixir ~> 1.14
- Basic understanding of Elixir and OTP
- An LLM application you want to instrument

## Installation

Add `agent_obs` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:agent_obs, "~> 0.1.0"}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

## Choosing a Backend

AgentObs supports multiple observability backends. Choose based on your needs:

### Arize Phoenix (Recommended for LLM Observability)

Best for:

- Deep LLM application insights
- Token usage and cost tracking
- Tool call visualization
- Chat message inspection

### Generic OpenTelemetry

Best for:

- Integration with existing APM tools
- Generic distributed tracing
- Custom observability platforms

### Multiple Backends

You can use both simultaneously for comprehensive observability.

## Basic Configuration

### Step 1: Configure AgentObs

In `config/config.exs`:

```elixir
config :agent_obs,
  enabled: true,
  handlers: [AgentObs.Handlers.Phoenix]
```

### Step 2: Configure OpenTelemetry SDK

In `config/runtime.exs`:

```elixir
config :opentelemetry,
  # Use batch processor for production efficiency
  span_processor: :batch,

  # Identify your service
  resource: [
    service: [
      name: System.get_env("OTEL_SERVICE_NAME", "my_llm_agent"),
      version: "1.0.0"
    ]
  ]

config :opentelemetry_exporter,
  # Protocol for exporting traces
  otlp_protocol: :http_protobuf,

  # Arize Phoenix endpoint (local or cloud)
  # Note: The exporter automatically appends /v1/traces to the endpoint
  otlp_endpoint: System.get_env(
    "ARIZE_PHOENIX_OTLP_ENDPOINT",
    "http://localhost:6006"
  ),

  # Optional: Add API key for cloud Phoenix
  otlp_headers: []
```

For cloud Arize Phoenix, add authentication:

```elixir
config :opentelemetry_exporter,
  otlp_endpoint: System.fetch_env!("ARIZE_PHOENIX_OTLP_ENDPOINT"),
  otlp_headers: [
    {"authorization", "Bearer #{System.fetch_env!("ARIZE_PHOENIX_API_KEY")}"}
  ]
```

### Step 3: Start Your Observability Backend

#### Local Arize Phoenix (Docker)

```bash
docker run -p 6006:6006 -p 4317:4317 arizephoenix/phoenix:latest
```

Then navigate to http://localhost:6006 to view traces.

#### Cloud Arize Phoenix

Sign up at https://app.arize.com and get your:

- OTLP endpoint URL
- API key

Set them as environment variables:

```bash
export ARIZE_PHOENIX_OTLP_ENDPOINT=your_endpoint
export ARIZE_PHOENIX_API_KEY=your_key
```

## Your First Instrumented Agent

Let's create a simple weather agent with complete instrumentation:

```elixir
defmodule MyApp.WeatherAgent do
  @moduledoc """
  A simple agent that provides weather information.
  """

  def run(query) do
    # Instrument the entire agent execution
    AgentObs.trace_agent("weather_agent", %{input: query}, fn ->
      # Step 1: Call LLM to understand the query
      {:ok, city, _meta} = extract_city(query)

      # Step 2: Fetch weather data using a tool
      {:ok, weather} = fetch_weather(city)

      # Step 3: Format the response
      response = format_response(city, weather)

      # Return result with metadata
      {:ok, response, %{
        city: city,
        tools_used: ["weather_api"],
        iterations: 1
      }}
    end)
  end

  defp extract_city(query) do
    # Instrument the LLM call
    AgentObs.trace_llm("gpt-4o-mini", %{
      input_messages: [
        %{role: "system", content: "Extract the city name from the user's query."},
        %{role: "user", content: query}
      ]
    }, fn ->
      # Make actual LLM API call
      response = call_openai(...)

      {:ok, response.city, %{
        output_messages: [%{role: "assistant", content: response.raw}],
        tokens: %{
          prompt: response.usage.prompt_tokens,
          completion: response.usage.completion_tokens,
          total: response.usage.total_tokens
        }
      }}
    end)
  end

  defp fetch_weather(city) do
    # Instrument the tool call
    AgentObs.trace_tool("weather_api", %{
      arguments: %{city: city, units: "celsius"},
      description: "Fetches current weather data for a city"
    }, fn ->
      # Make actual API call (or mock for demo)
      # In production: HTTPoison.get("https://api.weather.com/v1/current?city=#{city}")
      # For demo purposes, return mock data:
      weather_data = %{
        temperature: 72,
        condition: "sunny",
        humidity: 45
      }

      {:ok, weather_data}
    end)
  end

  defp format_response(city, weather) do
    """
    The weather in #{city} is currently #{weather.condition}.
    Temperature: #{weather.temperature}°C
    Humidity: #{weather.humidity}%
    """
  end

  # Simplified OpenAI call (use actual API in production)
  defp call_openai(_messages) do
    # In production, use OpenAI client library here
    # For demo purposes, we'll return mock data
    %{
      city: "San Francisco",
      raw: "The city is San Francisco",
      usage: %{
        prompt_tokens: 15,
        completion_tokens: 10,
        total_tokens: 25
      }
    }
  end
end
```

## Running Your Agent

### Using the Demo

The fastest way to see AgentObs in action is with the included demo:

```bash
cd demo
mix deps.get
iex -S mix

# In IEx, run a demo scenario:
Demo.run_all()

# Or try a custom question:
Demo.Scenarios.custom("What is 15 multiplied by 7?")
```

### Using Your Own Agent

```elixir
# Start your application
iex -S mix

# Run the agent
MyApp.WeatherAgent.run("What's the weather like in San Francisco?")
```

**Note:** The weather example above uses mock data. For a working example with
real LLM calls and tool execution, see the `demo/` directory in the AgentObs
repository.

## Viewing Your Traces

1. Open http://localhost:6006 in your browser
2. You should see a trace with:
   - An `weather_agent` span (parent)
   - An `gpt-4o-mini` span (LLM call)
   - A `weather_api` span (tool call)

The Phoenix UI will show:

- **Messages**: Input/output for each LLM call
- **Tokens**: Token counts and costs
- **Tools**: Tool calls with arguments and results
- **Timeline**: Execution duration and relationships

## Understanding Trace Structure

AgentObs creates nested spans that represent your agent's execution:

```
weather_agent (3.2s)
├── gpt-4o-mini (1.5s)           # LLM call to extract city
└── weather_api (200ms)          # Tool call to fetch weather
```

Each span includes:

- **Name**: Operation identifier
- **Duration**: Time taken
- **Attributes**: Metadata (tokens, costs, etc.)
- **Events**: Key moments during execution
- **Status**: Success or error

## Next Steps

Now that you have basic instrumentation working, explore:

- **[Configuration Guide](configuration.md)** - Advanced configuration options,
  production setup, and troubleshooting
- **[Instrumentation Guide](instrumentation.md)** - Best practices, patterns, and
  advanced techniques for complex agents
- **[ReqLLM Integration](req_llm_integration.md)** - Simplified streaming
  instrumentation with automatic metadata extraction (recommended for streaming)
- **[Custom Handlers](custom_handlers.md)** - Building your own backend handlers
  for custom observability platforms

### Quick Links

**For Production Deployment:**

- [Production Best Practices](configuration.md#production-best-practices)
- [Environment-Specific Configuration](configuration.md#environment-specific-configuration)
- [Security Considerations](configuration.md#production-best-practices)

**For Complex Agents:**

- [Multi-Stage Pipeline Pattern](instrumentation.md#pattern-3-multi-stage-pipeline)
- [Streaming Agents with ReqLLM](instrumentation.md#pattern-4-streaming-agent-reqllm)
- [Nested Agent Calls](instrumentation.md#nested-agent-calls)

**For Custom Backends:**

- [Handler Behaviour](custom_handlers.md#handler-architecture)
- [Complete Handler Examples](custom_handlers.md#complete-handler-examples)

## Troubleshooting

### Traces not appearing?

1. **Check AgentObs is enabled:**

   ```elixir
   # In iex
   Application.get_env(:agent_obs, :enabled)
   # Should return: true
   ```

2. **Verify handlers are configured:**

   ```elixir
   Application.get_env(:agent_obs, :handlers)
   # Should return: [AgentObs.Handlers.Phoenix]
   ```

3. **Check OpenTelemetry exporter:**

   ```bash
   # Make sure Phoenix is running
   curl http://localhost:6006
   ```

4. **Enable debug logging:**
   ```elixir
   # config/dev.exs
   config :logger, level: :debug
   ```

### Performance impact?

AgentObs uses OpenTelemetry's batch processor by default, which:

- Buffers spans in memory
- Exports asynchronously
- Minimal impact on your application's latency

For production, the overhead is typically < 1% of total execution time.

### Need help?

- Check the [full documentation](https://hexdocs.pm/agent_obs)
- Open an issue on [GitHub](https://github.com/your-org/agent_obs/issues)
