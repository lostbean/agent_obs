# AgentObs Demo

A complete demonstration environment showcasing AgentObs instrumentation with a real LLM agent, dual observability backends, and comprehensive tracing.

## 🎯 What This Demo Shows

- **Instrumented LLM Agent** - req_llm-based agent with tool calling capabilities
- **Dual Observability** - Same traces sent to both Arize Phoenix (OpenInference) and Jaeger (generic OTel)
- **Complete Tracing** - Agent loops, LLM calls, and tool executions all instrumented
- **Real LLM Interactions** - Uses Anthropic Claude via req_llm
- **Docker Compose Setup** - One-command environment startup

## 📋 Prerequisites

- **Docker** and **Docker Compose** installed
- **Elixir 1.14+** and **Erlang/OTP 25+**
- **API Key** - Anthropic API key (or OpenAI API key)

## 🚀 Quick Start

### 1. Setup Environment

```bash
cd demo

# Copy environment template
cp .env.example .env

# Edit .env and add your API key
# Required: ANTHROPIC_API_KEY or OPENAI_API_KEY
nano .env
```

### 2. Start Services

```bash
./scripts/start.sh
```

This will:
- Start Arize Phoenix (port 6006)
- Start Jaeger (port 16686)
- Install demo dependencies
- Wait for services to be healthy

### 3. Run Demo Scenarios

You can run the demo with different observability backends:

#### Option A: Run with Phoenix (OpenInference format)
```bash
./scripts/run_demo_phoenix.sh
```

#### Option B: Run with Jaeger (Generic OpenTelemetry)
```bash
./scripts/run_demo_jaeger.sh
```

Each script runs four demo scenarios:
1. **Calculator** - Math operations with tool calling
2. **Weather** - Information retrieval (mocked)
3. **Multi-step** - Complex agent loop with multiple tools

### 4. View Traces

**Arize Phoenix (OpenInference format):**
- URL: http://localhost:6006
- Look for service: `agent_obs_demo`
- Features rich LLM context: messages, token counts, tool calls
- Run demo with: `./scripts/run_demo_phoenix.sh`

**Jaeger (Generic OpenTelemetry):**
- URL: http://localhost:16686
- Look for service: `agent_obs_demo`
- Shows basic span structure and timing
- Run demo with: `./scripts/run_demo_jaeger.sh`

💡 **Tip:** Run the demo twice (once with each backend) to compare how the same traces appear in different UIs!

### 5. Stop Services

```bash
./scripts/stop.sh
```

## 📊 Demo Scenarios

### Scenario 1: Calculator Demo

Tests tool calling with math operations:
- "What is 15 multiplied by 7?"
- "Calculate the square root of 144"
- "What's 100 divided by 4, then add 25?"

**What to observe:**
- Agent span wrapping entire execution
- LLM span for model interaction
- Tool spans for calculator execution
- Token counts and costs (in Phoenix)

### Scenario 2: Weather Demo

Tests information retrieval (mocked web search):
- "Search for current weather conditions in San Francisco"
- "What's the weather like in Tokyo?"

**What to observe:**
- Tool calling with web_search
- Multiple LLM calls (initial + tool result processing)
- Nested span relationships

### Scenario 3: Multi-Step Demo

Complex agent loop with multiple operations:
- Calculate 25 * 4
- Search for information about that number
- Calculate square root

**What to observe:**
- Multiple tool calls in sequence
- Conversation context maintained
- Complete agent loop lifecycle

## 🎮 Running Custom Scenarios

You can run individual scenarios or custom questions:

```bash
# Run specific scenario with Phoenix
./scripts/run_demo_phoenix.sh calculator_demo
./scripts/run_demo_phoenix.sh weather_demo
./scripts/run_demo_phoenix.sh multi_step_demo

# Run specific scenario with Jaeger
./scripts/run_demo_jaeger.sh calculator_demo

# Run custom question (from Elixir)
OTLP_BACKEND=phoenix mix run -e 'Demo.Scenarios.custom("What is 2 + 2?")'
OTLP_BACKEND=jaeger mix run -e 'Demo.Scenarios.custom("What is 2 + 2?")'

# Interactive mode
OTLP_BACKEND=phoenix iex -S mix
iex> Demo.Scenarios.custom("Your question here")
```

## 🔍 Understanding the Traces

### Arize Phoenix View

Phoenix uses OpenInference semantic conventions, providing:

- **Rich Message Display** - Chat messages shown as conversation
- **Token Tracking** - Prompt/completion token counts
- **Cost Calculation** - Estimated costs per LLM call
- **Tool Call Details** - Function names, arguments, and results
- **Structured Metadata** - Organized by event type

Navigate to traces and filter by:
- Service: `agent_obs_demo`
- Span type: `AGENT`, `LLM`, `TOOL`

### Jaeger View

Jaeger shows generic OpenTelemetry spans:

- **Timeline View** - Visual span hierarchy and timing
- **Duration Analysis** - Time spent in each operation
- **Basic Attributes** - Key-value pairs for each span
- **Service Dependencies** - Not applicable (single service)

Search for:
- Service: `agent_obs_demo`
- Operation: `llm_agent`, `calculator`, etc.

### Comparing Both Views

**Same Trace, Different Perspectives:**
- Phoenix: Optimized for LLM/AI observability
- Jaeger: General-purpose distributed tracing

**Use Phoenix for:**
- Debugging LLM responses
- Analyzing token usage and costs
- Understanding tool call flow
- Evaluating agent behavior

**Use Jaeger for:**
- Performance analysis
- Latency debugging
- General span timing
- Traditional APM workflows

## 🏗️ Architecture

```
┌─────────────────┐
│  Demo.Agent     │  ← Instrumented with AgentObs.ReqLLM helpers
│  (GenServer)    │
└────────┬────────┘
         │
         ├─► AgentObs.trace_agent/3
         ├─► AgentObs.ReqLLM.trace_stream_text/3
         └─► AgentObs.ReqLLM.trace_tool_execution/3
                │
                ├─► Phoenix Handler → OpenInference → Phoenix UI
                └─► Generic Handler → OTel → Jaeger UI
```

## 📁 Project Structure

```
demo/
├── docker-compose.yml       # Phoenix + Jaeger services
├── .env.example             # Environment template
├── mix.exs                  # Demo dependencies
├── config/
│   ├── config.exs          # AgentObs dual-backend setup
│   └── runtime.exs         # OTel configuration
├── lib/
│   ├── demo.ex             # Main module
│   ├── demo/
│   │   ├── application.ex  # OTP application
│   │   ├── agent.ex        # Instrumented agent (uses AgentObs.ReqLLM helpers)
│   │   └── scenarios.ex    # Demo scenarios
└── scripts/
    ├── start.sh            # Start all services
    ├── run_demo_phoenix.sh # Run demo with Phoenix backend
    ├── run_demo_jaeger.sh  # Run demo with Jaeger backend
    └── stop.sh             # Stop services
```

## 🔧 Configuration

### Environment Variables (.env)

```bash
# Required: At least one API key
ANTHROPIC_API_KEY=sk-ant-...
OPENAI_API_KEY=sk-...

# Observability (defaults work with Docker Compose)
# Note: OpenTelemetry library automatically appends /v1/traces
ARIZE_PHOENIX_OTLP_ENDPOINT=http://localhost:6006
JAEGER_OTLP_ENDPOINT=http://localhost:4318

# Service name
OTEL_SERVICE_NAME=agent_obs_demo

# Model selection
DEFAULT_MODEL=anthropic:claude-sonnet-4-20250514
```

### AgentObs Configuration (config/config.exs)

The demo supports switching backends via the `OTLP_BACKEND` environment variable:

```elixir
# OTLP_BACKEND=phoenix (default) → Uses Phoenix handler with OpenInference
# OTLP_BACKEND=jaeger → Uses Generic handler for standard OTel
# OTLP_BACKEND=both → Uses both handlers (dual instrumentation)

backend = System.get_env("OTLP_BACKEND", "phoenix")

handlers =
  case backend do
    "jaeger" -> [AgentObs.Handlers.Generic]
    "both" -> [AgentObs.Handlers.Phoenix, AgentObs.Handlers.Generic]
    _ -> [AgentObs.Handlers.Phoenix]
  end

config :agent_obs,
  enabled: true,
  handlers: handlers,
  event_prefix: [:demo]
```

### OpenTelemetry Configuration (config/runtime.exs)

The OTLP exporter endpoint is configured based on the backend:

```elixir
backend = System.get_env("OTLP_BACKEND", "phoenix")

otlp_endpoint =
  case backend do
    "jaeger" -> "http://localhost:4318"  # Jaeger OTLP endpoint
    _ -> "http://localhost:6006"         # Phoenix OTLP endpoint
  end

config :opentelemetry_exporter,
  otlp_protocol: :http_protobuf,
  otlp_endpoint: otlp_endpoint
```

## 🐛 Troubleshooting

### Services Won't Start

```bash
# Check Docker is running
docker --version
docker-compose --version

# Check ports are available
lsof -i :6006
lsof -i :16686

# View service logs
docker-compose logs phoenix
docker-compose logs jaeger
```

### No Traces Appearing

```bash
# Verify services are healthy
curl http://localhost:6006
curl http://localhost:16686

# Check OTel endpoint configuration
echo $ARIZE_PHOENIX_OTLP_ENDPOINT

# Run with debug logging
LOG_LEVEL=debug mix run -e "Demo.Scenarios.calculator_demo()"
```

### API Key Issues

```bash
# Verify API key is set
echo $ANTHROPIC_API_KEY | cut -c1-10

# Test API key manually
curl https://api.anthropic.com/v1/messages \
  -H "anthropic-version: 2023-06-01" \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "content-type: application/json" \
  -d '{"model":"claude-3-5-sonnet-20241022","messages":[{"role":"user","content":"Hi"}],"max_tokens":10}'
```

### Dependencies Issues

```bash
# Clean and reinstall
rm -rf _build deps
mix deps.clean --all
mix deps.get
mix compile
```

## 💡 Tips & Best Practices

1. **Start Simple** - Run calculator demo first to verify setup
2. **Compare UIs** - Open same trace in both Phoenix and Jaeger
3. **Experiment** - Modify scenarios or create custom questions
4. **Watch Logs** - Agent prints to console in real-time
5. **Clean Slate** - Restart services between demos for clarity

## 🔗 Related Links

- [AgentObs Documentation](../README.md)
- [req_llm Documentation](https://hexdocs.pm/req_llm)
- [Arize Phoenix Docs](https://arize.com/docs/phoenix/)
- [Jaeger Documentation](https://www.jaegertracing.io/docs/)
- [OpenInference Spec](https://arize-ai.github.io/openinference/spec/semantic_conventions.html)

## 📝 Next Steps

After exploring the demo:

1. **Instrument Your Agent** - Apply AgentObs to your own LLM agent
2. **Customize Handlers** - Create backend-specific handlers
3. **Production Deployment** - Configure for production observability platforms
4. **Extend Scenarios** - Add more complex agent workflows
5. **Analyze Performance** - Use traces to optimize agent behavior

## 🤝 Contributing

Found an issue or have a suggestion? Please open an issue in the main repository.

## 📄 License

This demo is part of the AgentObs project and uses the same MIT license.
