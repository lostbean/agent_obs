# **Building AgentObs: An Elixir Library for LLM Agent Observability**

## **I. Introduction: A New Frontier for Observability in Elixir LLM Agents**

### **The Paradigm Shift in Application Monitoring**

The discipline of application monitoring is undergoing a fundamental
transformation, driven by the rise of Large Language Model (LLM) powered agentic
systems. Traditional Application Performance Monitoring (APM) has long been the
cornerstone of operational health, focusing on a well-understood set of metrics:
request latency, error rates, CPU utilization, and memory consumption. These
metrics are effective for applications built on deterministic logic, where a
given input reliably produces a predictable output and errors manifest as
exceptions or non-2xx status codes. LLM agents, however, operate on a different
paradigm. Their behavior is probabilistic, not deterministic. An agent's
execution path can be emergent and complex, involving multiple steps of
reasoning, tool invocation, and self-correction.1 In this new world, a
successful 200 OK HTTP response from an agent endpoint reveals very little about
the quality or correctness of the outcome. The critical questions shift from "Is
the service up?" to "Was the answer correct?", "Did the agent hallucinate?",
"Did it select and use the appropriate tool with the correct arguments?", and
"How many tokens were consumed, and what was the associated cost?". This shift
necessitates a move beyond conventional APM towards a more nuanced form of
observability. The telemetry data captured must be semantically rich, providing
deep context into the agent's internal "thought process." It is no longer
sufficient to know that an operation took 500 milliseconds; it is essential to
understand the content of the prompts, the arguments passed to tools, the
retrieved context from vector stores, and the final generated response. This
reframes observability from a passive health check into an active, indispensable
component of the development, evaluation, and validation lifecycle for AI
systems. A generic tracing solution is inadequate for this task. The solution
must understand the specific semantics of LLM operations, a challenge directly
addressed by the OpenInference specification, an extension of the OpenTelemetry
standard designed for AI observability.2

### **The BEAM and Elixir as a Premier Platform for AI Orchestration**

The Elixir programming language, built upon the Erlang Open Telecom Platform
(OTP), offers a uniquely powerful foundation for building the sophisticated,
concurrent, and fault-tolerant systems required for AI orchestration. The BEAM
virtual machine's lightweight, isolated processes and the OTP framework's
built-in supervision strategies provide an ideal environment for managing
complex, multi-agent workflows. Each agent, tool, or sub-task can be modeled as
a supervised process, ensuring that failures are contained and the overall
system remains resilient. Elixir's prowess in data transformation, pattern
matching, and handling I/O-bound tasks further solidifies its position as an
excellent choice for the "connective tissue" of modern AI applications,
orchestrating calls to various LLMs, APIs, and data sources.

### **Introducing AgentObs**

This report details the design and implementation of AgentObs, a reusable Elixir
library created to bridge the gap between Elixir's powerful runtime and the new
frontier of LLM observability. The mission of AgentObs is to provide a simple,
powerful, and idiomatic interface for Elixir developers to instrument their LLM
agentic applications. It achieves this through a two-layer architecture:

**Layer 1: Core Telemetry API (Backend-Agnostic)**

1. Leveraging Elixir's native :telemetry ecosystem for low-overhead event
   emission.
2. Providing high-level helpers for instrumenting agent loops, tool calls, LLM
   requests, and prompt construction.
3. Defining a standardized event schema that is independent of any specific
   observability backend.

**Layer 2: Pluggable Backend Handlers**

1. Integrating with the official OpenTelemetry Elixir SDK to create and manage
   distributed traces.
2. Implementing modular handler backends, starting with Arize Phoenix support
   via OpenInference semantic conventions.
3. Enabling future extensibility to other observability platforms (Langfuse,
   CloudWatch, Datadog, etc.) without changing instrumentation code.

The following sections provide a comprehensive architectural blueprint, a
detailed implementation guide, and production-readiness considerations for
building the AgentObs library from the ground up.

## **II. Architectural Blueprint: Scaffolding the AgentObs Library**

### **Initializing a Supervised Application**

The foundation of a robust and reusable Elixir library, especially one intended
to manage background tasks and configuration, begins with its project structure.
The standard mix new command is the entry point for any new Elixir project.5 For
AgentObs, the choice is made to initialize the project as a supervised
application rather than a plain library:

Bash

mix new agent_obs \--sup

This decision is deliberate and architecturally significant. The \--sup flag
scaffolds the project with an application callback module and a supervision tree
out of the box.7 While a simple telemetry handler could be attached directly by
a user's application, this approach is brittle. A production-grade library
should encapsulate its own state and manage its lifecycle. The telemetry
handlers will need to hold configuration (e.g., event prefixes, enabled status)
and could be extended in the future to manage a pool of workers for asynchronous
batch exporting. According to OTP principles, any component that manages runtime
properties such as mutable state, concurrency, or initialization and shutdown
logic should be modeled as a process.7 By starting with a supervision tree,
AgentObs becomes a self-contained, fault-tolerant component that integrates
cleanly into the lifecycle of any host application, a critical distinction for a
library designed for widespread, reliable use.

### **Configuring mix.exs**

The mix.exs file is the heart of the project's configuration, defining its
dependencies, metadata, and build instructions.6 For AgentObs, this file is
configured to meet the standards of the Elixir ecosystem.

#### **Dependencies**

The library's functionality is built upon a curated set of dependencies that
bridge the Elixir, Telemetry, and OpenTelemetry ecosystems. Consolidating these
from various setup guides ensures a correct and complete starting point for
developers.8 **Table 1: Core Library Dependencies**

| Package                               | Recommended Version | Purpose                                                                                                                                                                                               |
| :------------------------------------ | :------------------ | :---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| {:telemetry, "\~\> 1.0"}              | \~\> 1.0            | The core Erlang/Elixir library for emitting and handling telemetry events. This is the foundation upon which the library's instrumentation is built.11                                                |
| {:opentelemetry_api, "\~\> 1.2"}      | \~\> 1.2            | Provides the core OpenTelemetry APIs and macros (Tracer.with_span, etc.) for creating spans and adding attributes within application code.9                                                           |
| {:opentelemetry, "\~\> 1.3"}          | \~\> 1.3            | The OpenTelemetry SDK implementation, which contains the logic for processing, sampling, and exporting telemetry data.9                                                                               |
| {:opentelemetry_exporter, "\~\> 1.6"} | \~\> 1.6            | Contains the OpenTelemetry Protocol (OTLP) exporter, which is responsible for sending formatted trace data to a compatible backend like Arize Phoenix.9                                               |
| {:jason, "\~\> 1.2"}                  | \~\> 1.2            | A high-performance JSON library, essential for serializing complex metadata attributes, such as tool arguments or invocation parameters, into the string format required by the OTLP specification.12 |
| {:ex_doc, "\~\> 0.28", only: :dev}    | \~\> 0.28           | The standard tool for generating high-quality HTML and EPUB documentation from inline code comments, reflecting the Elixir community's emphasis on documentation as a first-class citizen.13          |

#### **Project Metadata and Documentation**

Following best practices for library development, the mix.exs file is also
populated with descriptive metadata, including a description, package
configuration specifying the files to be published, maintainer information, and
a license (e.g., Apache 2.0, same as Elixir itself).5 The inclusion of ex_doc
in the dependencies underscores a commitment to providing comprehensive and
accessible documentation, a hallmark of a mature Elixir project.7

### **Structuring the Library: Two-Layer Architecture**

A clear module structure is essential for maintainability and comprehensibility.
The AgentObs library is organized into two distinct layers, each with
well-defined responsibilities. All modules are namespaced under the AgentObs
prefix to avoid conflicts with the host application's modules.7

#### **Layer 1: Core Telemetry API (Backend-Agnostic)**

- AgentObs (lib/agent_obs.ex): The main entry point and public API. Exposes
  high-level instrumentation helpers like `trace_agent/3`, `trace_tool/3`,
  `trace_llm/3`, and low-level `emit/2` for custom events.
- AgentObs.Application (lib/agent_obs/application.ex): The OTP application
  callback module generated by mix new \--sup. Starts the library's supervision
  tree and configured handlers.
- AgentObs.Events (lib/agent_obs/events.ex): Defines the standardized event
  schema and metadata structures for agent loops, tool calls, LLM requests, and
  prompts. This is the contract that all handlers implement.
- AgentObs.Req (lib/agent_obs/req.ex): Integration helpers for automatic
  instrumentation of `req` and `req_llm` HTTP requests.

#### **Layer 2: Pluggable Backend Handlers**

- AgentObs.Handler (lib/agent_obs/handler.ex): A behaviour defining the contract
  for all backend handlers. Specifies callbacks like `handle_event/4` and
  `attach/1`.
- AgentObs.Handlers.Phoenix (lib/agent_obs/handlers/phoenix.ex): Arize Phoenix
  backend implementation. A GenServer that attaches to :telemetry events and
  creates OpenTelemetry spans with OpenInference semantic conventions.
- AgentObs.Handlers.Phoenix.Translator
  (lib/agent_obs/handlers/phoenix/translator.ex): Pure function module for
  transforming AgentObs event metadata into OpenInference attributes.
- AgentObs.Handlers.Generic (lib/agent_obs/handlers/generic.ex): Basic
  OpenTelemetry handler without OpenInference conventions, for generic OTel
  backends.
- AgentObs.Supervisor (lib/agent_obs/supervisor.ex): Supervises configured
  handler processes with a one_for_one strategy.

## **III. Public API Reference: Instrumenting Your Agent**

Before diving into implementation details, this section defines the user-facing
API that developers will use to instrument their LLM agents. AgentObs provides
both high-level convenience helpers and low-level primitives for maximum
flexibility.

### **High-Level Instrumentation Helpers**

These functions wrap common agent operations in telemetry spans, automatically
handling event emission with standardized metadata structures.

#### **AgentObs.trace_agent/3**

Instruments an agent loop or agent invocation.

```elixir
AgentObs.trace_agent(name, metadata, fun)
```

**Parameters:**

- `name` (string): Human-readable name for the agent operation
- `metadata` (map): Context about the agent invocation
  - `:input` - The input/query/task given to the agent
  - `:model` (optional) - The routing or orchestration model used
  - `:metadata` (optional) - Additional custom metadata
- `fun` (function): The agent logic to execute

**Returns:** The result of `fun`, which should be `{:ok, output, metadata}` or
`{:error, reason}`

**Example:**

```elixir
AgentObs.trace_agent("weather_assistant", %{input: "What's the weather?"}, fn ->
  # Agent logic here
  {:ok, "It's sunny", %{tools_used: ["weather_api"]}}
end)
```

#### **AgentObs.trace_tool/3**

Instruments a tool call or function execution within an agent.

```elixir
AgentObs.trace_tool(tool_name, metadata, fun)
```

**Parameters:**

- `tool_name` (string): Name of the tool being invoked
- `metadata` (map): Tool invocation context
  - `:arguments` - The arguments passed to the tool (map or JSON string)
  - `:description` (optional) - Tool description
- `fun` (function): The tool execution logic

**Returns:** The result of `fun`, typically `{:ok, result}` or
`{:error, reason}`

**Example:**

```elixir
AgentObs.trace_tool("get_weather", %{arguments: %{city: "SF"}}, fn ->
  {:ok, %{temp: 72, condition: "sunny"}}
end)
```

#### **AgentObs.trace_llm/3**

Instruments an LLM API call (chat completion, embedding, etc.).

```elixir
AgentObs.trace_llm(model, metadata, fun)
```

**Parameters:**

- `model` (string): The LLM model identifier (e.g., "gpt-4o", "claude-3-opus")
- `metadata` (map): LLM call context
  - `:input_messages` - List of message maps with `:role` and `:content`
  - `:type` (optional) - "chat", "completion", "embedding" (default: "chat")
  - `:temperature`, `:max_tokens`, etc. - Model parameters
- `fun` (function): The LLM API call logic

**Returns:** The result of `fun`, should include token usage and cost data:
`{:ok, response, %{tokens: %{prompt: X, completion: Y}, cost: Z}}`

**Example:**

```elixir
AgentObs.trace_llm("gpt-4o", %{
  input_messages: [%{role: "user", content: "Hello"}]
}, fn ->
  response = call_openai_api()
  {:ok, response.content, %{
    output_messages: [%{role: "assistant", content: response.content}],
    tokens: %{prompt: 10, completion: 25},
    cost: 0.00015
  }}
end)
```

#### **AgentObs.trace_prompt/3**

Instruments prompt construction or template rendering.

```elixir
AgentObs.trace_prompt(template_name, metadata, fun)
```

**Parameters:**

- `template_name` (string): Name of the prompt template
- `metadata` (map): Template rendering context
  - `:variables` - Variables used in template rendering
  - `:template` (optional) - The template string itself
- `fun` (function): The prompt rendering logic

**Example:**

```elixir
AgentObs.trace_prompt("system_prompt", %{
  variables: %{user_name: "Alice", task: "weather"}
}, fn ->
  {:ok, render_template(@system_template, variables)}
end)
```

### **Low-Level Event Emission**

For custom instrumentation needs not covered by the high-level helpers:

#### **AgentObs.emit/2**

Emits a custom telemetry event with AgentObs standardized metadata.

```elixir
AgentObs.emit(event_type, metadata)
```

**Parameters:**

- `event_type` (atom): One of `:agent`, `:tool`, `:llm`, `:prompt`, or custom
  type
- `metadata` (map): Event-specific metadata

**Example:**

```elixir
AgentObs.emit(:custom_event, %{
  name: "vector_search",
  input: query,
  output: results,
  metadata: %{index: "docs", k: 10}
})
```

### **Configuration API**

#### **AgentObs.configure/1**

Runtime configuration of handlers and options.

```elixir
AgentObs.configure(opts)
```

**Parameters:**

- `opts` (keyword list):
  - `:handlers` - List of handler modules to enable (e.g.,
    `[AgentObs.Handlers.Phoenix]`)
  - `:event_prefix` - Custom event prefix (default: `[:agent_obs]`)
  - `:enabled` - Enable/disable instrumentation (default: `true`)

**Example:**

```elixir
AgentObs.configure(
  handlers: [AgentObs.Handlers.Phoenix],
  event_prefix: [:my_app, :ai]
)
```

### **ReqLLM Integration**

For applications using the [ReqLLM](https://hexdocs.pm/req_llm) library, AgentObs provides high-level helper functions that wrap ReqLLM's streaming API with automatic instrumentation.

#### **Why ReqLLM Instead of Low-Level Req Middleware?**

ReqLLM is a unified interface to AI providers that already handles:

- Parsing provider-specific streaming responses
- Extracting token usage and costs
- Normalizing tool calls across providers
- Managing conversation context

By integrating at the ReqLLM level (instead of low-level Req middleware), AgentObs leverages these abstractions rather than duplicating them.

#### **Installation**

Add `:req_llm` as an optional dependency:

```elixir
def deps do
  [
    {:agent_obs, "~> 0.1"},
    {:req_llm, "~> 1.0.0-rc.7"}
  ]
end
```

#### **AgentObs.ReqLLM.trace_stream_text/3**

Wraps `ReqLLM.stream_text/3` with automatic instrumentation:

```elixir
{:ok, stream_response} =
  AgentObs.ReqLLM.trace_stream_text(
    "anthropic:claude-3-5-sonnet",
    [%{role: "user", content: "Hello!"}]
  )

# Stream output in real-time
stream_response.stream
|> Stream.filter(&(&1.type == :content))
|> Stream.each(&IO.write(&1.text))
|> Stream.run()
```

This automatically:

- Creates an LLM span with OpenInference attributes
- Extracts token usage from `ReqLLM.StreamResponse.usage/1`
- Parses tool calls from streaming chunks
- Captures finish reason and metadata

#### **AgentObs.ReqLLM.trace_tool_execution/3**

Wraps tool execution with instrumentation:

```elixir
tool = ReqLLM.Tool.new!(
  name: "calculator",
  callback: &calculator/1
)

tool_call = %{name: "calculator", arguments: %{"expr" => "2 + 2"}}

{:ok, result} = AgentObs.ReqLLM.trace_tool_execution(tool, tool_call)
```

#### **Complete Agent Loop Example**

```elixir
defmodule MyAgent do
  def chat(model, message, tools) do
    AgentObs.trace_agent("my_agent", %{input: message}, fn ->
      # Instrumented LLM call
      {:ok, stream_response} =
        AgentObs.ReqLLM.trace_stream_text(model,
          [%{role: "user", content: message}],
          tools: tools
        )

      # Extract results
      text = ReqLLM.StreamResponse.text(stream_response)
      tool_calls = ReqLLM.StreamResponse.extract_tool_calls(stream_response)

      # Execute tools with instrumentation
      Enum.each(tool_calls, fn tc ->
        tool = Enum.find(tools, & &1.name == tc.name)
        AgentObs.ReqLLM.trace_tool_execution(tool, tc)
      end)

      {:ok, text, %{
        tools_used: Enum.map(tool_calls, & &1.name),
        iterations: if(tool_calls == [], do: 1, else: 2)
      }}
    end)
  end
end
```

**Benefits:**

- No manual token extraction
- No manual tool call parsing
- Automatic instrumentation across all ReqLLM providers
- Streaming preserved (non-blocking instrumentation)
- Compatible with ReqLLM's provider-agnostic API

## **IV. The Instrumentation Layer: Core Event Schema and Telemetry Integration**

### **A Primer on :telemetry.span/3**

The core of instrumentation in AgentObs relies on the :telemetry library. While
:telemetry.execute/3 can be used to emit discrete events, the :telemetry.span/3
function is perfectly suited for instrumenting operations with a distinct start
and end, such as an LLM call or a tool execution.11 The function signature is
span(EventPrefix, StartMetadata, SpanFunction). It works by:

1. Immediately emitting a start event with the name EventPrefix \++ \[:start\],
   including the StartMetadata.
2. Executing the provided SpanFunction.
3. Upon successful completion, it measures the duration and emits a stop event:
   EventPrefix \++ \[:stop\]. The measurements map will contain the duration,
   and the metadata will include the return value of the function.
4. If the function raises an exception, it emits an exception event: EventPrefix
   \++ \[:exception\], providing details about the error.14

This behavior provides a consistent, predictable set of events for any
instrumented operation, simplifying the handler logic significantly. A mock
agent function would be instrumented as follows:

Elixir

defmodule MyApp.Agent do def run(prompt) do event_prefix \= \[:my_app, :agent,
:run\] start_metadata \= %{input: prompt, llm_model: "gpt-4o"}

    :telemetry.span(event\_prefix, start\_metadata, fn \-\>
      \#... agent logic: call LLM, use tools, etc....
      {:ok, "Agent response.", %{token\_usage: 120}}
    end)

end end

### **Configuring the OpenTelemetry SDK**

Before spans can be created, the OpenTelemetry SDK must be configured in the
host application's config/runtime.exs. This ensures the configuration is
evaluated at runtime, allowing the use of environment variables for production
deployments.

- **Span Processor:** The SDK is configured to use the :batch span processor.
  This processor collects spans in a buffer and exports them in batches, which
  is significantly more performant in production than the SimpleSpanProcessor
  that exports each span individually as it completes. This avoids blocking
  application processes on every single span export.15
- **Resource Attributes:** A crucial piece of configuration is the resource
  block. Setting the service.name attribute is essential, as this is how the
  application will be identified and grouped within the Arize Phoenix UI. Other
  attributes can be added to provide further context about the deployment
  environment.8

### **Connecting to Arize Phoenix**

The final step in configuration is telling the OTLP exporter where and how to
send the trace data. This involves specifying the OTLP endpoint for the Arize
Phoenix instance and providing the necessary authentication credentials. Arize
Phoenix accepts traces over the OpenTelemetry Protocol (OTLP) and can be run
locally or in the cloud.16 It exposes both a gRPC endpoint (typically on port
4317\) and an HTTP endpoint (typically on port 6006).18 Using the HTTP endpoint
(:http_protobuf) is often preferable for its ease of debugging and
compatibility with standard web proxies. Authentication for a secured Phoenix
instance is handled via API keys, which can be either System or User keys.20
These keys must be sent as a Bearer token in the authorization header of the
OTLP request.21 The following table and configuration snippet consolidate these
requirements into a single, production-ready setup. **Table 2: Arize Phoenix
OTLP Configuration**

| Configuration Key | runtime.exs Value                                 | Environment Variable        | Purpose                                                                                                                |
| :---------------- | :------------------------------------------------ | :-------------------------- | :--------------------------------------------------------------------------------------------------------------------- |
| traces_exporter   | :otlp                                             | N/A                         | Specifies that the OpenTelemetry SDK should use the OTLP exporter.15                                                   |
| otlp_protocol     | :http_protobuf                                    | OTEL_EXPORTER_OTLP_PROTOCOL | Sets the transport protocol. :http_protobuf is recommended for its broad compatibility.8                               |
| otlp_endpoint     | System.fetch_env\!("ARIZE_PHOENIX_OTLP_ENDPOINT") | ARIZE_PHOENIX_OTLP_ENDPOINT | The full URL to the Phoenix OTLP HTTP ingest endpoint (e.g., http://localhost:6006/v1/traces).18                       |
| otlp_headers      | \`\`                                              | OTEL_EXPORTER_OTLP_HEADERS  | The authentication headers required by a secured Phoenix instance, using a System or User API key as a Bearer token.21 |
| resource          | \[service: \[name: "my_llm_agent"\]\]             | OTEL_RESOURCE_ATTRIBUTES    | Identifies the service in the Phoenix UI, allowing traces to be filtered and grouped correctly.8                       |

A complete configuration block in config/runtime.exs would look like this:

Elixir

\# In config/runtime.exs import Config

if config_env() \== :prod do config :opentelemetry, span_processor: :batch,
resource: \[service: \[name: "my_llm_agent"\]\]

config :opentelemetry_exporter, otlp_protocol: :http_protobuf,
otlp_endpoint: System.fetch_env\!("ARIZE_PHOENIX_OTLP_ENDPOINT"),
otlp_headers: end

## **V. Handler Layer: Modular Backend Architecture**

### **The AgentObs.Handler Behaviour**

To support multiple observability backends without changing instrumentation
code, AgentObs defines a behaviour that all backend handlers must implement.
This creates a pluggable architecture where new backends can be added by simply
implementing the behaviour.

```elixir
# In lib/agent_obs/handler.ex
defmodule AgentObs.Handler do
  @moduledoc """
  Behaviour for AgentObs backend handlers.

  Handlers receive telemetry events emitted by AgentObs instrumentation
  and translate them to backend-specific formats (OpenTelemetry spans,
  logs, metrics, etc.).
  """

  @doc """
  Attaches the handler to telemetry events.

  Called during handler initialization. Should use :telemetry.attach_many/4
  to register for relevant events.

  Returns `{:ok, state}` or `{:error, reason}`.
  """
  @callback attach(config :: map()) :: {:ok, term()} | {:error, term()}

  @doc """
  Handles a telemetry event.

  Called synchronously when an attached event is emitted.
  """
  @callback handle_event(
    event_name :: [atom()],
    measurements :: map(),
    metadata :: map(),
    config :: term()
  ) :: :ok

  @doc """
  Detaches the handler from telemetry events.

  Called during handler termination. Should clean up any resources.
  """
  @callback detach(state :: term()) :: :ok
end
```

### **Phoenix Handler: OpenInference Translation**

The AgentObs.Handlers.Phoenix module implements the handler behaviour for Arize
Phoenix, creating OpenTelemetry spans with OpenInference semantic conventions.

```elixir
# In lib/agent_obs/handlers/phoenix.ex
defmodule AgentObs.Handlers.Phoenix do
  use GenServer
  @behaviour AgentObs.Handler

  require OpenTelemetry.Tracer, as: Tracer
  alias AgentObs.Handlers.Phoenix.Translator

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl AgentObs.Handler
  def attach(config) do
    event_prefix = Map.get(config, :event_prefix, [:agent_obs])
    handler_id = {:agent_obs_phoenix, event_prefix, self()}

    events_to_attach = [
      event_prefix ++ [:agent, :start],
      event_prefix ++ [:agent, :stop],
      event_prefix ++ [:agent, :exception],
      event_prefix ++ [:tool, :start],
      event_prefix ++ [:tool, :stop],
      event_prefix ++ [:tool, :exception],
      event_prefix ++ [:llm, :start],
      event_prefix ++ [:llm, :stop],
      event_prefix ++ [:llm, :exception],
      event_prefix ++ [:prompt, :start],
      event_prefix ++ [:prompt, :stop],
      event_prefix ++ [:prompt, :exception]
    ]

    :ok = :telemetry.attach_many(
      handler_id,
      events_to_attach,
      &__MODULE__.handle_event/4,
      config
    )

    {:ok, %{handler_id: handler_id, config: config}}
  end

  @impl AgentObs.Handler
  def handle_event(event_name, measurements, metadata, config) do
    event_type = get_event_type(event_name)

    case List.last(event_name) do
      :start -> handle_start(event_type, metadata)
      :stop -> handle_stop(event_type, measurements, metadata)
      :exception -> handle_exception(event_type, measurements, metadata)
    end
  end

  @impl AgentObs.Handler
  def detach(state) do
    :telemetry.detach(state.handler_id)
  end

  # Private functions for span management
  defp get_event_type(event_name) do
    event_name
    |> Enum.reverse()
    |> Enum.drop(1)
    |> List.last()
  end

  defp handle_start(event_type, metadata) do
    attributes = Translator.from_start_metadata(event_type, metadata)
    span_name = Map.get(metadata, :name, "#{event_type}-operation")

    ctx = Tracer.start_span(span_name, %{attributes: attributes})
    Process.put(:agent_obs_span_ctx, ctx)
    :ok
  end

  defp handle_stop(event_type, measurements, metadata) do
    with {:ok, ctx} <- fetch_span_context() do
      span = OpenTelemetry.Span.get_context(ctx)
      attributes = Translator.from_stop_metadata(event_type, metadata, measurements)

      Tracer.set_attributes(span, attributes)
      Tracer.end_span(span)

      Process.delete(:agent_obs_span_ctx)
    end

    :ok
  end

  defp handle_exception(event_type, measurements, metadata) do
    with {:ok, ctx} <- fetch_span_context() do
      span = OpenTelemetry.Span.get_context(ctx)
      attributes = Translator.from_exception_metadata(event_type, metadata, measurements)

      Tracer.set_attributes(span, attributes)
      Tracer.record_exception(span, metadata.kind, metadata.reason, metadata.stacktrace)
      Tracer.set_status(span, :error, "Exception occurred")
      Tracer.end_span(span)

      Process.delete(:agent_obs_span_ctx)
    end

    :ok
  end

  defp fetch_span_context do
    case Process.get(:agent_obs_span_ctx) do
      nil -> {:error, :no_active_span}
      ctx -> {:ok, ctx}
    end
  end
end
```

### **Generic Handler: Basic OpenTelemetry**

For backends that don't support OpenInference, a generic OpenTelemetry handler
is provided.

```elixir
# In lib/agent_obs/handlers/generic.ex
defmodule AgentObs.Handlers.Generic do
  @behaviour AgentObs.Handler
  @moduledoc """
  Generic OpenTelemetry handler without OpenInference conventions.

  Creates basic OTel spans with simplified attributes for any
  OpenTelemetry-compatible backend.
  """

  # Similar structure to Phoenix handler but with simpler attribute translation
end
```

### **Supervisor Configuration**

The AgentObs.Supervisor starts configured handlers based on application config.

```elixir
# In lib/agent_obs/supervisor.ex
defmodule AgentObs.Supervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    handlers = Application.get_env(:agent_obs, :handlers, [])

    children = Enum.map(handlers, fn handler_module ->
      {handler_module, get_handler_config(handler_module)}
    end)

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp get_handler_config(handler_module) do
    Application.get_env(:agent_obs, handler_module, %{})
  end
end
```

## **VI. Core Event Schema: Standardized Metadata Structures**

This section defines the standardized event schema that AgentObs uses across all
backends. This schema is backend-agnostic and represents the contract between
instrumentation code and handler implementations.

### **Event Types and Metadata Structures**

AgentObs defines four primary event types, each with a standardized metadata
structure:

#### **Agent Events**

Emitted by `AgentObs.trace_agent/3` for agent loop or invocation tracking.

**Event Name:** `[:agent_obs, :agent, :start | :stop | :exception]`

**Start Metadata:**

```elixir
%{
  name: "weather_assistant",           # Required: Agent name
  input: "What's the weather in SF?",  # Required: Input query/task
  model: "gpt-4o-router",              # Optional: Routing model
  metadata: %{...}                     # Optional: Custom metadata
}
```

**Stop Metadata (return value from function):**

```elixir
%{
  output: "It's sunny in SF",          # Required: Agent output
  tools_used: ["weather_api"],         # Optional: Tools invoked
  iterations: 3,                       # Optional: Agent loop count
  metadata: %{...}                     # Optional: Custom metadata
}
```

#### **Tool Events**

Emitted by `AgentObs.trace_tool/3` for tool call tracking.

**Event Name:** `[:agent_obs, :tool, :start | :stop | :exception]`

**Start Metadata:**

```elixir
%{
  name: "get_weather",                 # Required: Tool name
  arguments: %{city: "SF"},            # Required: Tool arguments (map or JSON string)
  description: "Fetches weather data"  # Optional: Tool description
}
```

**Stop Metadata:**

```elixir
%{
  result: %{temp: 72, condition: "sunny"}  # Required: Tool execution result
}
```

#### **LLM Events**

Emitted by `AgentObs.trace_llm/3` for LLM API call tracking.

**Event Name:** `[:agent_obs, :llm, :start | :stop | :exception]`

**Start Metadata:**

```elixir
%{
  model: "gpt-4o",                     # Required: Model identifier
  input_messages: [                    # Required for chat models
    %{role: "user", content: "Hello"}
  ],
  type: "chat",                        # Optional: "chat" | "completion" | "embedding"
  temperature: 0.7,                    # Optional: Model parameters
  max_tokens: 1000,                    # Optional
  metadata: %{...}                     # Optional: Custom metadata
}
```

**Stop Metadata:**

```elixir
%{
  output_messages: [                   # Required for chat models
    %{role: "assistant", content: "Hi there!"}
  ],
  tokens: %{                           # Optional but recommended
    prompt: 10,
    completion: 25,
    total: 35
  },
  cost: 0.00015,                       # Optional: Cost in USD
  finish_reason: "stop"                # Optional: "stop" | "length" | "tool_calls"
}
```

#### **Prompt Events**

Emitted by `AgentObs.trace_prompt/3` for prompt template tracking.

**Event Name:** `[:agent_obs, :prompt, :start | :stop | :exception]`

**Start Metadata:**

```elixir
%{
  name: "system_prompt",               # Required: Template name
  variables: %{user: "Alice"},         # Required: Template variables
  template: "You are..."               # Optional: Template string
}
```

**Stop Metadata:**

```elixir
%{
  rendered: "You are helping Alice..." # Required: Rendered prompt
}
```

### **AgentObs.Events Module**

The `AgentObs.Events` module provides validation and normalization functions for
these event schemas:

```elixir
# In lib/agent_obs/events.ex
defmodule AgentObs.Events do
  @moduledoc """
  Defines and validates standardized event schemas for AgentObs.
  """

  @event_types [:agent, :tool, :llm, :prompt]

  def validate_event(event_type, :start, metadata) when event_type in @event_types do
    # Validation logic for start metadata
  end

  def validate_event(event_type, :stop, metadata) when event_type in @event_types do
    # Validation logic for stop metadata
  end

  def normalize_metadata(event_type, phase, metadata) do
    # Normalization logic (e.g., converting atoms to strings)
  end
end
```

## **VII. Phoenix Translator: Mapping to OpenInference Semantic Conventions**

### **A Deep Dive into OpenInference for Agents**

The AgentObs.Handlers.Phoenix.Translator module is where the standardized
AgentObs event metadata is transformed into the OpenInference semantic
conventions format.25 This translation is specific to the Arize Phoenix backend
and enables Phoenix to provide a rich, contextualized UI for LLM traces, with
dedicated views for chat messages, tool calls, and token counts.3

The translator is a pure function module that takes AgentObs event metadata as
input and produces flattened OpenTelemetry attributes conforming to
OpenInference. This keeps backend-specific logic isolated from the core
instrumentation API.

Key attributes from the specification that are relevant for agentic systems
include 25:

- openinference.span.kind: Identifies the type of operation (e.g., "AGENT",
  "LLM", "TOOL"). This is a required attribute for all OpenInference spans.
- input.value / output.value: The primary input and output of the operation,
  typically a string or JSON string.
- llm.model_name: The specific model used (e.g., "gpt-4o").
- llm.input_messages / llm.output_messages: For chat-based models, these
  capture the list of messages exchanged.
- message.tool_calls: A list of tool calls requested by the model in its
  response.
- tool.name / tool.description: The name and description of a tool that was
  executed.
- llm.token_count.prompt / llm.token_count.completion: The number of tokens
  used.
- llm.cost.total: The calculated cost of the LLM call in USD.

### **Implementing the Phoenix Translator**

The Phoenix.Translator is a pure module that transforms AgentObs standardized
event metadata into OpenInference semantic conventions. Its central challenge is
converting nested Elixir data structures (like a list of message maps) into the
flattened, indexed key format required by OpenTelemetry and OpenInference.

For example, the spec requires a list of input messages to be represented not as
a single attribute with a list value, but as a series of distinct attributes
like `llm.input_messages.0.message.role`,
`llm.input_messages.0.message.content`, `llm.input_messages.1.message.role`, and
so on.25 This requires recursive transformation functions that traverse nested
maps and lists.

```elixir
# In lib/agent_obs/handlers/phoenix/translator.ex
defmodule AgentObs.Handlers.Phoenix.Translator do
  @moduledoc """
  Translates AgentObs event metadata to OpenInference semantic conventions.
  """

  def from_start_metadata(:agent, metadata) do
    %{
      "openinference.span.kind" => "AGENT",
      "input.value" => metadata.input
    }
    |> maybe_add("llm.model_name", metadata[:model])
  end

  def from_start_metadata(:llm, metadata) do
    %{
      "openinference.span.kind" => "LLM",
      "llm.model_name" => metadata.model
    }
    |> Map.merge(flatten_input_messages(metadata[:input_messages]))
  end

  def from_stop_metadata(:llm, metadata, measurements) do
    %{}
    |> Map.merge(flatten_output_messages(metadata[:output_messages]))
    |> maybe_add("llm.token_count.prompt", get_in(metadata, [:tokens, :prompt]))
    |> maybe_add("llm.token_count.completion", get_in(metadata, [:tokens, :completion]))
    |> maybe_add("llm.cost.total", metadata[:cost])
    |> add_duration(measurements)
  end

  # Flattening helpers
  defp flatten_input_messages(messages) when is_list(messages) do
    messages
    |> Enum.with_index()
    |> Enum.flat_map(fn {msg, idx} ->
      [
        {"llm.input_messages.#{idx}.message.role", to_string(msg.role)},
        {"llm.input_messages.#{idx}.message.content", msg.content}
      ]
    end)
    |> Map.new()
  end

  defp maybe_add(map, _key, nil), do: map
  defp maybe_add(map, key, value), do: Map.put(map, key, value)
end
```

The following table serves as a "Rosetta Stone," providing the mapping between
AgentObs event metadata and OpenInference attributes.

**Table 3: AgentObs-to-OpenInference Mapping Reference**

| Elixir Metadata (Example)                                                                                                    | OpenInference Attribute                                                 | Value Type             |
| :--------------------------------------------------------------------------------------------------------------------------- | :---------------------------------------------------------------------- | :--------------------- |
| %{kind: :agent}                                                                                                              | openinference.span.kind                                                 | String ("AGENT")       |
| %{input: "What is Elixir?"}                                                                                                  | input.value                                                             | String                 |
| %{output: "A dynamic, functional language..."}                                                                               | output.value                                                            | String                 |
| %{llm: %{model_name: "gpt-4o"}}                                                                                              | llm.model_name                                                          | String ("gpt-4o")      |
| %{llm: %{input_messages: \[%{role: :user, content: "Hi"}\]}}                                                                 | llm.input_messages.0.message.role                                       | String ("user")        |
|                                                                                                                              | llm.input_messages.0.message.content                                    | String ("Hi")          |
| %{llm: %{output_messages: \[%{role: :assistant, tool_calls: \[%{function: %{name: "get_weather", arguments: "{...}"}}\]}\]}} | llm.output_messages.0.message.role                                      | String ("assistant")   |
|                                                                                                                              | llm.output_messages.0.message.tool_calls.0.tool_call.function.name      | String ("get_weather") |
|                                                                                                                              | llm.output_messages.0.message.tool_calls.0.tool_call.function.arguments | JSON String            |
| %{llm: %{token_count: %{prompt: 10, completion: 25}}}                                                                        | llm.token_count.prompt                                                  | Integer (10)           |
|                                                                                                                              | llm.token_count.completion                                              | Integer (25)           |
| %{llm: %{cost: %{total: 0.0015}}}                                                                                            | llm.cost.total                                                          | Float (0.0015)         |

## **VI. End-to-End Workflow: From Agent Action to Phoenix Trace**

### **Creating a Sample LLM Agent**

To demonstrate the complete workflow, a simple agent is created that uses the
AgentObs library. This agent will use the high-level `AgentObs.trace_agent/3`
helper to automatically emit telemetry events. First, the host application must
configure AgentObs in its application config to enable the Phoenix handler.

```elixir
# In config/config.exs
config :agent_obs,
  handlers: [AgentObs.Handlers.Phoenix],
  event_prefix: [:my_app]

# In config/runtime.exs (for Phoenix backend)
config :agent_obs, AgentObs.Handlers.Phoenix,
  endpoint: System.fetch_env!("ARIZE_PHOENIX_OTLP_ENDPOINT"),
  api_key: System.fetch_env!("ARIZE_PHOENIX_API_KEY")
```

Next, the sample agent module is defined using the high-level AgentObs API:

```elixir
# In the host application
defmodule MyApp.WeatherAgent do
  def get_forecast(city) do
    AgentObs.trace_agent("weather_forecast", %{
      input: "What is the weather in #{city}?"
    }, fn ->
      # 1. Use trace_llm for the LLM call
      {:ok, tool_call, llm_metadata} = call_llm_for_tool_selection(city)

      # 2. Use trace_tool for tool execution
      {:ok, weather_data} = AgentObs.trace_tool("lookup_weather_api", %{
        arguments: %{city: city}
      }, fn ->
        {:ok, %{temp: 72, condition: "sunny"}}
      end)

      # 3. Final response
      final_response = "The weather in #{city} is #{weather_data.condition}."

      {:ok, final_response, %{
        tools_used: ["lookup_weather_api"],
        iterations: 1
      }}
    end)
  end

  defp call_llm_for_tool_selection(city) do
    AgentObs.trace_llm("gpt-4o", %{
      input_messages: [
        %{role: "user", content: "Get weather for #{city}"}
      ]
    }, fn ->
      tool_call = %{
        function: %{
          name: "lookup_weather_api",
          arguments: Jason.encode!(%{city: city})
        }
      }

      {:ok, tool_call, %{
        output_messages: [%{role: "assistant", tool_calls: [tool_call]}],
        tokens: %{prompt: 50, completion: 25, total: 75},
        cost: 0.00012
      }}
    end)
  end
end
```

### **Tracing the Data Flow**

When MyApp.WeatherAgent.get_forecast("SF") is called, the following sequence of
events occurs:

1. The :telemetry.span/3 call immediately emits a \[:my_app, :agent, :start\]
   event with the start_metadata.
2. The AgentObs.Handlers.Phoenix, which is attached to this event, receives it
   in its handle_event/4 function.
3. The handle_start clause is executed. It calls the
   AgentObs.Handlers.Phoenix.Translator to convert the start_metadata into
   flattened OpenInference attributes.
4. An OpenTelemetry span named "get_forecast_for_SF" is created with these
   attributes and set as the active span in the current process.
5. The agent's anonymous function executes, performing the mock LLM and tool
   calls.
6. The function successfully returns, and :telemetry.span/3 emits a \[:my_app,
   :agent, :stop\] event. The measurements map contains the duration, and the
   metadata map contains the stop_metadata from the function's return value.
7. The AgentObs.Handlers.Phoenix receives the :stop event.
8. The handle_stop clause retrieves the active span, translates the
   stop_metadata and measurements into more OpenInference attributes, and adds
   them to the span.
9. The span is marked as ended.
10. The OpenTelemetry Batch Processor receives the completed span and adds it to
    its buffer.
11. Periodically, the Batch Processor sends the buffer of spans to the OTLP
    exporter.
12. The exporter constructs an HTTP POST request containing the protobuf-encoded
    span data, adds the Authorization: Bearer... header, and sends it to the
    configured Arize Phoenix endpoint.

### **Visualizing the Result in Arize Phoenix**

The ultimate payoff for meticulously adhering to the OpenInference standard is
realized in the Arize Phoenix user interface. Because the trace data is
semantically structured, Phoenix can provide a far richer visualization than a
generic trace viewer.3 Instead of a simple timeline with a long list of
key-value attributes, the trace view for the agent's execution will feature
specialized UI components:

- **Trace Overview:** The span will be clearly labeled with its name,
  "get_forecast_for_SF", and its kind, "AGENT".
- **Chat View:** The llm.input_messages and llm.output_messages attributes
  will be rendered as a familiar chat interface, showing the user's prompt and
  the assistant's response.
- **Tool Call Display:** The tool_calls within the assistant's message will be
  highlighted, clearly showing the function name (lookup_weather_api) and its
  JSON arguments.
- **Metrics Panel:** Key metrics like llm.token_count.total (75) and
  llm.cost.total ($0.00012) will be prominently displayed, enabling immediate
  cost and usage analysis.
- **Input/Output:** The top-level input.value and output.value will be shown,
  providing a quick summary of the span's purpose and result.

This rich, contextualized display demonstrates the value proposition of the
AgentObs library: it doesn't just export data; it enables a superior diagnostic
and evaluation experience in a purpose-built observability platform.

## **VII. Production Readiness and Best Practices**

### **Configuration: Core and Backend-Specific Settings**

For a library to be production-ready, its configuration must be flexible and
decoupled from its code. AgentObs uses a two-layer configuration approach that
separates core library settings from backend-specific configuration.

#### **Core Configuration**

Core settings control AgentObs behavior independent of any backend:

```elixir
# In config/config.exs
config :agent_obs,
  enabled: true,                              # Enable/disable all instrumentation
  handlers: [AgentObs.Handlers.Phoenix],      # List of handler modules to start
  event_prefix: [:my_app]                     # Custom event prefix (default: [:agent_obs])
```

These settings are read by `AgentObs.Application` to control the supervision
tree and determine which handlers to start.

#### **Backend-Specific Configuration**

Each handler backend has its own configuration namespace:

**Phoenix Handler Configuration:**

```elixir
# In config/runtime.exs (for environment variables)
config :agent_obs, AgentObs.Handlers.Phoenix,
  endpoint: System.fetch_env!("ARIZE_PHOENIX_OTLP_ENDPOINT"),
  api_key: System.fetch_env!("ARIZE_PHOENIX_API_KEY"),
  batch_size: 100,                            # Optional: spans per batch
  batch_timeout: 5000                         # Optional: ms to wait before export
```

**Generic Handler Configuration:**

```elixir
config :agent_obs, AgentObs.Handlers.Generic,
  endpoint: System.fetch_env!("OTEL_OTLP_ENDPOINT"),
  headers: []                                 # Optional: custom headers
```

#### **Environment-Specific Configuration**

Different environments can use different backends:

```elixir
# In config/dev.exs - Use Phoenix locally
config :agent_obs,
  handlers: [AgentObs.Handlers.Phoenix]

config :agent_obs, AgentObs.Handlers.Phoenix,
  endpoint: "http://localhost:6006/v1/traces",
  api_key: nil                                # No auth for local Phoenix

# In config/prod.exs - Use multiple backends
config :agent_obs,
  handlers: [
    AgentObs.Handlers.Phoenix,                # For detailed LLM observability
    AgentObs.Handlers.Generic                 # For APM integration
  ]

# In config/test.exs - Disable instrumentation
config :agent_obs,
  enabled: false
```

This separation allows users to:

1. Switch backends without changing instrumentation code
2. Use multiple backends simultaneously
3. Configure backends independently
4. Easily disable instrumentation per environment

### **Performance Considerations: Asynchronous Exporting**

The synchronous nature of :telemetry handlers, while beneficial for context
propagation, presents a potential performance bottleneck. If the OTLP collector
is slow to respond or the network is latent, the application process that
emitted the telemetry event will be blocked, directly increasing the latency of
the application's core logic. For high-throughput systems, a more advanced,
fully non-blocking architecture can be implemented. In this model, the
AgentObs.Handlers.Phoenix's handle_event/4 function would perform the absolute
minimum work possible. Instead of creating and managing the OpenTelemetry span
directly, it would package the event name, measurements, and metadata into a
message and send it asynchronously (e.g., via GenServer.cast or by using a
library like Broadway) to a separate pool of worker processes. These background
workers, running independently of the application's request-response cycle,
would then be responsible for the potentially slow operations: translating the
metadata, creating the OpenTelemetry span, and handing it off to the exporter.
This design completely decouples the application's performance from the
observability pipeline, ensuring that instrumentation has a near-zero latency
impact, a critical feature for production-grade systems.

### **Testing Strategy: Multi-Layer Validation**

A comprehensive test suite is non-negotiable for a library intended for
production use. AgentObs' two-layer architecture requires a multi-faceted
testing approach.

#### **1. Unit Testing: Event Schema Validation**

Test the `AgentObs.Events` module's validation and normalization functions:

```elixir
# In test/agent_obs/events_test.exs
defmodule AgentObs.EventsTest do
  use ExUnit.Case

  test "validates agent start metadata" do
    valid_metadata = %{name: "my_agent", input: "task"}
    assert :ok = AgentObs.Events.validate_event(:agent, :start, valid_metadata)

    invalid_metadata = %{name: "my_agent"}  # missing required :input
    assert {:error, _} = AgentObs.Events.validate_event(:agent, :start, invalid_metadata)
  end

  test "normalizes LLM metadata" do
    metadata = %{model: "gpt-4o", input_messages: [%{role: :user, content: "Hi"}]}
    normalized = AgentObs.Events.normalize_metadata(:llm, :start, metadata)

    assert normalized.input_messages == [%{role: "user", content: "Hi"}]
  end
end
```

#### **2. Unit Testing: Translator Logic**

Test translator modules in isolation as pure functions:

```elixir
# In test/agent_obs/handlers/phoenix/translator_test.exs
defmodule AgentObs.Handlers.Phoenix.TranslatorTest do
  use ExUnit.Case
  alias AgentObs.Handlers.Phoenix.Translator

  test "translates agent start metadata to OpenInference" do
    metadata = %{name: "weather_agent", input: "What's the weather?"}
    attributes = Translator.from_start_metadata(:agent, metadata)

    assert attributes["openinference.span.kind"] == "AGENT"
    assert attributes["input.value"] == "What's the weather?"
  end

  test "flattens LLM input messages correctly" do
    metadata = %{
      model: "gpt-4o",
      input_messages: [
        %{role: "user", content: "Hello"},
        %{role: "assistant", content: "Hi there!"}
      ]
    }

    attributes = Translator.from_start_metadata(:llm, metadata)

    assert attributes["llm.input_messages.0.message.role"] == "user"
    assert attributes["llm.input_messages.0.message.content"] == "Hello"
    assert attributes["llm.input_messages.1.message.role"] == "assistant"
    assert attributes["llm.input_messages.1.message.content"] == "Hi there!"
  end
end
```

#### **3. Contract Testing: Handler Behaviour**

Test that all handler implementations correctly implement the behaviour:

```elixir
# In test/agent_obs/handler_contract_test.exs
defmodule AgentObs.HandlerContractTest do
  use ExUnit.Case

  @handlers [AgentObs.Handlers.Phoenix, AgentObs.Handlers.Generic]

  for handler <- @handlers do
    test "#{handler} implements attach/1 callback" do
      assert function_exported?(unquote(handler), :attach, 1)

      config = %{event_prefix: [:test]}
      {:ok, state} = unquote(handler).attach(config)
      assert is_map(state) or is_list(state)
    end

    test "#{handler} implements handle_event/4 callback" do
      assert function_exported?(unquote(handler), :handle_event, 4)
    end

    test "#{handler} implements detach/1 callback" do
      assert function_exported?(unquote(handler), :detach, 1)
    end
  end
end
```

#### **4. Integration Testing: End-to-End Instrumentation**

Test the complete flow from instrumentation to span export:

```elixir
# In test/agent_obs/integration_test.exs
defmodule AgentObs.IntegrationTest do
  use ExUnit.Case

  setup do
    # Use in-memory test exporter
    :otel_batch_processor.set_exporter(:otel_exporter_pid, self())
    :ok
  end

  test "trace_agent emits correct OpenTelemetry spans" do
    AgentObs.trace_agent("test_agent", %{input: "test task"}, fn ->
      {:ok, "result", %{}}
    end)

    # Assert span was exported
    assert_receive {:span, span}
    assert span.name == "test_agent"
    assert span.attributes["openinference.span.kind"] == "AGENT"
    assert span.attributes["input.value"] == "test task"
  end

  test "nested spans create correct parent-child relationships" do
    AgentObs.trace_agent("parent", %{input: "task"}, fn ->
      AgentObs.trace_llm("gpt-4o", %{input_messages: []}, fn ->
        {:ok, "response", %{tokens: %{total: 10}}}
      end)

      {:ok, "done", %{}}
    end)

    assert_receive {:span, child_span}
    assert_receive {:span, parent_span}

    assert child_span.parent_span_id == parent_span.span_id
    assert child_span.attributes["openinference.span.kind"] == "LLM"
    assert parent_span.attributes["openinference.span.kind"] == "AGENT"
  end
end
```

#### **5. Multi-Backend Validation**

Test that the same instrumentation works correctly with different backends:

```elixir
# In test/agent_obs/multi_backend_test.exs
defmodule AgentObs.MultiBackendTest do
  use ExUnit.Case

  test "instrumentation works with Phoenix handler" do
    # Configure Phoenix handler
    start_supervised!({AgentObs.Handlers.Phoenix, %{event_prefix: [:test]}})

    AgentObs.trace_llm("gpt-4o", %{input_messages: []}, fn ->
      {:ok, "response", %{tokens: %{prompt: 10, completion: 20}}}
    end)

    # Assert OpenInference attributes present
    assert_receive {:span, span}
    assert span.attributes["llm.token_count.prompt"] == 10
  end

  test "instrumentation works with Generic handler" do
    # Configure Generic handler
    start_supervised!({AgentObs.Handlers.Generic, %{event_prefix: [:test]}})

    AgentObs.trace_tool("calculator", %{arguments: %{op: "add"}}, fn ->
      {:ok, 42}
    end)

    # Assert basic OTel attributes present (no OpenInference)
    assert_receive {:span, span}
    assert span.name == "calculator"
    refute Map.has_key?(span.attributes, "openinference.span.kind")
  end
end
```

This comprehensive testing strategy ensures:

1. **Core event schema is validated** independently of backends
2. **Translation logic is correct** for each backend
3. **Handler behaviour contract is enforced** for all implementations
4. **End-to-end instrumentation works** as expected
5. **Multiple backends can coexist** without conflicts

## **VIII. Conclusion**

The AgentObs library, as designed and detailed in this report, provides a robust
and idiomatic solution for a critical challenge in the modern software
landscape: the observability of LLM agentic systems. By thoughtfully combining
the strengths of the BEAM, the flexibility of :telemetry, and the industry
standards of OpenTelemetry and OpenInference, it offers Elixir developers a
clear path to gaining deep, contextual insights into their AI applications. The
architectural decisions—from using a supervised OTP application structure to
separating stateful handling from pure data transformation—ensure that the
library is not only functional but also resilient, performant, and maintainable.
The detailed focus on adhering to the OpenInference semantic conventions is the
key that unlocks the full potential of specialized observability platforms like
Arize Phoenix, transforming raw trace data into actionable insights about agent
behavior, cost, and quality. This report serves as a complete blueprint for
building such a library. Future enhancements could include the development of
macros for even simpler instrumentation, automatic instrumentation for popular
Elixir LLM client libraries, and extending support to include OpenTelemetry
metrics and logs, providing a truly comprehensive observability solution for the
growing ecosystem of AI-powered applications built on Elixir.

#### **Works cited**

1. LLM Observability in the Wild – Why OpenTelemetry Should Be the Standard |
   Hacker News, accessed October 21, 2025,
   [https://news.ycombinator.com/item?id=45398467](https://news.ycombinator.com/item?id=45398467)
2. What is OpenInference? | Arize Docs, accessed October 21, 2025,
   [https://arize.com/docs/ax/observe/tracing/tracing-concepts/what-is-openinference](https://arize.com/docs/ax/observe/tracing/tracing-concepts/what-is-openinference)
3. Arize Phoenix, accessed October 21, 2025,
   [https://arize.com/docs/phoenix](https://arize.com/docs/phoenix)
4. Arize Phoenix Alternative? Langfuse vs. Arize AI for LLM Observability,
   accessed October 21, 2025,
   [https://langfuse.com/faq/all/best-phoenix-arize-alternatives](https://langfuse.com/faq/all/best-phoenix-arize-alternatives)
5. Library guidelines — Elixir v1.20.0-dev \- HexDocs, accessed October 21,
   2025,
   [https://hexdocs.pm/elixir/main/library-guidelines.html](https://hexdocs.pm/elixir/main/library-guidelines.html)
6. Mix \- Elixir School, accessed October 21, 2025,
   [https://elixirschool.com/en/lessons/basics/mix](https://elixirschool.com/en/lessons/basics/mix)
7. Library Guidelines — Elixir v1.12.3 \- HexDocs, accessed October 21, 2025,
   [https://hexdocs.pm/elixir/1.12.3/library-guidelines.html](https://hexdocs.pm/elixir/1.12.3/library-guidelines.html)
8. Elixir, OpenTelemetry, and the Infamous N+1 · The Phoenix Files, accessed
   October 21, 2025,
   [https://fly.io/phoenix-files/opentelemetry-and-the-infamous-n-plus-1/](https://fly.io/phoenix-files/opentelemetry-and-the-infamous-n-plus-1/)
9. Getting Started \- OpenTelemetry, accessed October 21, 2025,
   [https://opentelemetry.io/docs/languages/erlang/getting-started/](https://opentelemetry.io/docs/languages/erlang/getting-started/)
10. OpenTelemetry Elixir Installation | AppSignal documentation, accessed
    October 21, 2025,
    [https://docs.appsignal.com/opentelemetry/installation/elixir.html](https://docs.appsignal.com/opentelemetry/installation/elixir.html)
11. telemetry v1.3.0 \- HexDocs, accessed October 21, 2025,
    [https://hexdocs.pm/telemetry/](https://hexdocs.pm/telemetry/)
12. Instrument your Elixir application with OpenTelemetry — Dynatrace Docs,
    accessed October 21, 2025,
    [https://docs.dynatrace.com/docs/ingest-from/opentelemetry/walkthroughs/elixir](https://docs.dynatrace.com/docs/ingest-from/opentelemetry/walkthroughs/elixir)
13. Writing and Publishing Elixir Libraries \- Yos Riady, accessed October 21,
    2025,
    [https://yos.io/2016/04/28/writing-and-publishing-elixir-libraries/](https://yos.io/2016/04/28/writing-and-publishing-elixir-libraries/)
14. beam-telemetry/telemetry: Dynamic dispatching library for metrics and
    instrumentations., accessed October 21, 2025,
    [https://github.com/beam-telemetry/telemetry](https://github.com/beam-telemetry/telemetry)
15. Erlang/Elixir OpenTelemetry SDK \- HexDocs, accessed October 21, 2025,
    [https://hexdocs.pm/opentelemetry/](https://hexdocs.pm/opentelemetry/)
16. Arize Phoenix | Arize Phoenix \- Arize AI, accessed October 21, 2025,
    [https://arize.com/docs/phoenix/](https://arize.com/docs/phoenix/)
17. Home \- Phoenix \- Arize AI, accessed October 21, 2025,
    [https://phoenix.arize.com/](https://phoenix.arize.com/)
18. Configuration | Arize Phoenix, accessed October 21, 2025,
    [https://arize.com/docs/phoenix/self-hosting/configuration](https://arize.com/docs/phoenix/self-hosting/configuration)
19. arize-phoenix-otel-multi \- PyPI, accessed October 21, 2025,
    [https://pypi.org/project/arize-phoenix-otel-multi/](https://pypi.org/project/arize-phoenix-otel-multi/)
20. API Keys | Arize Phoenix \- Arize AI, accessed October 21, 2025,
    [https://arize.com/docs/phoenix/settings/api-keys](https://arize.com/docs/phoenix/settings/api-keys)
21. Authentication | Arize Phoenix, accessed October 21, 2025,
    [https://arize.com/docs/phoenix/self-hosting/features/authentication](https://arize.com/docs/phoenix/self-hosting/features/authentication)
22. Arize Phoenix OSS \- LiteLLM, accessed October 21, 2025,
    [https://docs.litellm.ai/docs/observability/phoenix_integration](https://docs.litellm.ai/docs/observability/phoenix_integration)
23. telemetry — telemetry v1.3.0 \- HexDocs, accessed October 21, 2025,
    [https://hexdocs.pm/telemetry/telemetry.html](https://hexdocs.pm/telemetry/telemetry.html)
24. Instrumenting Phoenix with Telemetry Part I: Telemetry Under The Hood | Blog
    · Elixir School, accessed October 21, 2025,
    [https://elixirschool.com/blog/instrumenting-phoenix-with-telemetry-part-one](https://elixirschool.com/blog/instrumenting-phoenix-with-telemetry-part-one)
25. Semantic Conventions | openinference \- GitHub Pages, accessed October 21,
    2025,
    [https://arize-ai.github.io/openinference/spec/semantic_conventions.html](https://arize-ai.github.io/openinference/spec/semantic_conventions.html)
26. Openinference Semantic Conventions | Arize Docs, accessed October 21, 2025,
    [https://arize.com/docs/ax/observe/tracing/tracing-concepts/openinference-semantic-conventions](https://arize.com/docs/ax/observe/tracing/tracing-concepts/openinference-semantic-conventions)
