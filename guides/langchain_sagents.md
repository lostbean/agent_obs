# LangChain & Sagents Integration Guide

AgentObs provides first-class integration with
[LangChain](https://hexdocs.pm/langchain) and
[Sagents](https://hexdocs.pm/sagents), offering callback-based and
middleware-based instrumentation for LLM agent applications.

## Table of Contents

- [Choosing an Integration](#choosing-an-integration)
- [LangChain Integration](#langchain-integration)
  - [Installation](#langchain-installation)
  - [run/2 - Full Lifecycle Wrapping](#run2---full-lifecycle-wrapping)
  - [instrument/2 - Direct Chain Instrumentation](#instrument2---direct-chain-instrumentation)
  - [callbacks/1 - Manual Callback Integration](#callbacks1---manual-callback-integration)
  - [Tool Tracing](#langchain-tool-tracing)
  - [Multi-Turn Loops (while_needs_response)](#multi-turn-loops-while_needs_response)
- [Sagents Integration](#sagents-integration)
  - [Installation](#sagents-installation)
  - [Middleware Setup](#middleware-setup)
  - [Tool Tracing in Sagents](#tool-tracing-in-sagents)
  - [Sub-Agent Delegation](#sub-agent-delegation)
- [Combining LangChain + Sagents](#combining-langchain--sagents)
- [Context Propagation](#context-propagation)
- [Span Hierarchy Reference](#span-hierarchy-reference)
- [Best Practices](#best-practices)
- [Common Pitfalls](#common-pitfalls)
- [Comparison: ReqLLM vs LangChain vs Sagents](#comparison-reqllm-vs-langchain-vs-sagents)
- [Troubleshooting](#troubleshooting)

## Choosing an Integration

AgentObs supports three LLM integration paths. Choose based on your stack:

| Integration | When to Use | What You Get |
|---|---|---|
| **ReqLLM** | Direct API calls to LLM providers | Streaming, token extraction, tool execution |
| **LangChain** | Using LangChain's `LLMChain` | Callback-based LLM + tool spans, multi-turn support |
| **Sagents** | Using Sagents agent framework | Middleware-based AGENT spans, per-iteration LLM tracing |

**LangChain + Sagents** work together: Sagents provides the agent lifecycle
(AGENT spans) while LangChain callbacks provide inner LLM and tool spans.

## LangChain Integration

### LangChain Installation

Add both dependencies to `mix.exs`:

```elixir
def deps do
  [
    {:agent_obs, "~> 0.1"},
    {:langchain, "~> 0.5"}
  ]
end
```

LangChain is an **optional** dependency. The `AgentObs.LangChain` module is
only available when `langchain` is present.

### run/2 - Full Lifecycle Wrapping

The simplest approach wraps `LLMChain.run/2` with an outer LLM span that
captures the entire chain execution:

```elixir
alias LangChain.Chains.LLMChain
alias LangChain.ChatModels.ChatAnthropic
alias LangChain.Message

{:ok, chain} =
  LLMChain.new!(%{
    llm: ChatAnthropic.new!(%{model: "claude-sonnet-4-5-20250929"}),
    messages: [Message.new_system!("You are helpful.")]
  })
  |> LLMChain.add_message(Message.new_user!("Hello!"))
  |> AgentObs.LangChain.run()
```

`run/2` automatically:
- Creates an outer LLM span
- Captures input and output messages
- Extracts token usage
- Traces tool executions
- Handles errors and exceptions

### instrument/2 - Direct Chain Instrumentation

For chains managed by Sagents or your own loop, use `instrument/2` to add
callbacks without wrapping execution:

```elixir
chain =
  LLMChain.new!(%{llm: model, messages: messages})
  |> LLMChain.add_tools(tools)
  |> AgentObs.LangChain.instrument()

# Run the chain yourself (or let Sagents run it)
{:ok, updated_chain} = LLMChain.run(chain)
```

Options:

- `:parent_ctx` - OTel context for `Task.async` boundaries
- `:trace_tools` - Enable/disable tool tracing (default: `true`)
- `:metadata` - Extra metadata attached to all emitted spans

```elixir
chain = AgentObs.LangChain.instrument(chain,
  metadata: %{agent_name: "researcher"},
  trace_tools: true
)
```

### callbacks/1 - Manual Callback Integration

For maximum control, get the raw callback map and add it yourself:

```elixir
LLMChain.new!(%{llm: model, messages: messages})
|> LLMChain.add_callback(AgentObs.LangChain.callbacks())
|> LLMChain.run()
```

This is equivalent to `instrument/2` but gives you the callback map directly.
Useful when you need to merge with other callbacks or conditionally add
instrumentation.

### LangChain Tool Tracing

Tool executions within a chain are automatically traced when using `run/2` or
`instrument/2` with `trace_tools: true` (the default):

```elixir
alias LangChain.Function

tool = Function.new!(%{
  name: "calculator",
  description: "Perform calculations",
  parameters_schema: %{
    type: "object",
    properties: %{expression: %{type: "string"}}
  },
  function: fn args, _context -> {:ok, "42"} end
})

{:ok, chain} =
  LLMChain.new!(%{llm: model})
  |> LLMChain.add_message(Message.new_user!("What is 6 * 7?"))
  |> LLMChain.add_tools([tool])
  |> AgentObs.LangChain.run(mode: :while_needs_response)
```

This produces the span hierarchy:

```
LLM (outer, run/2)
  LLM (iteration 1: tool-calling turn)
    TOOL: calculator
  LLM (iteration 2: final answer)
```

To disable tool tracing while keeping LLM spans:

```elixir
chain = AgentObs.LangChain.instrument(chain, trace_tools: false)
```

### Multi-Turn Loops (while_needs_response)

When using `mode: :while_needs_response`, `run/2` creates per-iteration child
LLM spans nested under the outer span:

```elixir
{:ok, chain} =
  LLMChain.new!(%{llm: model})
  |> LLMChain.add_message(Message.new_user!("Research topic X"))
  |> LLMChain.add_tools(tools)
  |> AgentObs.LangChain.run(mode: :while_needs_response)
```

Each iteration through the LLM loop creates:
1. An LLM `:start` event when the assistant message arrives
2. Tool spans for any tool executions
3. An LLM `:stop` event when tokens arrive or tools complete

This gives full visibility into how many LLM round-trips occurred and what
happened in each one.

## Sagents Integration

### Sagents Installation

Add both dependencies to `mix.exs`:

```elixir
def deps do
  [
    {:agent_obs, "~> 0.1"},
    {:sagents, "~> 0.1"}
  ]
end
```

Sagents is an **optional** dependency. The `AgentObs.Sagents` module is only
available when `sagents` is present.

### Middleware Setup

Add `AgentObs.Sagents` to your agent's middleware stack. Place it **first** for
accurate timing:

```elixir
alias Sagents.Agent
alias LangChain.ChatModels.ChatAnthropic

agent =
  Agent.new!(
    %{
      agent_id: "my-agent",
      model: ChatAnthropic.new!(%{model: "claude-sonnet-4-5-20250929"}),
      middleware: [
        AgentObs.Sagents,
        Sagents.Middleware.TodoList,
        Sagents.Middleware.FileSystem
      ]
    }
  )
```

With options:

```elixir
middleware: [
  {AgentObs.Sagents, [trace_tools: true]},
  Sagents.Middleware.TodoList
]
```

The middleware emits:
- `[:agent_obs, :agent, :start]` in `before_model` (opens AGENT span)
- `[:agent_obs, :agent, :stop]` in `after_model` (closes AGENT span with output
  and token usage)

Each iteration of the agent loop produces a separate AGENT span, giving you
per-turn visibility.

### Tool Tracing in Sagents

Tool tracing in Sagents is handled at the LangChain chain level, not through
the middleware. Pass `AgentObs.LangChain.callbacks()` when executing the agent:

```elixir
alias Sagents.State
alias LangChain.Message

state = State.new!(%{
  messages: [Message.new_user!("What's the weather in SF?")]
})

{:ok, final_state} =
  Agent.execute(agent, state,
    callbacks: AgentObs.LangChain.callbacks()
  )
```

This produces the full hierarchy:

```
AGENT: my-agent (from Sagents middleware)
  LLM (from LangChain callbacks - tool-calling turn)
    TOOL: get_weather
  LLM (from LangChain callbacks - final answer)
```

### Sub-Agent Delegation

When using `Sagents.Middleware.SubAgent`, the parent agent can delegate to
sub-agents. Each agent in the chain gets its own AGENT span:

```elixir
alias Sagents.SubAgent.Config

agent =
  Agent.new!(
    %{
      agent_id: "orchestrator",
      model: model,
      middleware: [
        AgentObs.Sagents,
        {Sagents.Middleware.SubAgent, [
          model: model,
          subagents: [
            Config.new!(%{
              name: "researcher",
              description: "Research facts and answer questions",
              system_prompt: "You are a researcher. Be concise.",
              tools: [lookup_tool]
            })
          ]
        ]}
      ]
    },
    replace_default_middleware: true
  )

{:ok, final_state} =
  Agent.execute(agent, state,
    callbacks: AgentObs.LangChain.callbacks()
  )
```

## Combining LangChain + Sagents

The recommended pattern for full observability is:

1. **Sagents middleware** for AGENT spans (lifecycle, input/output)
2. **LangChain callbacks** for LLM and TOOL spans (per-iteration detail)

```elixir
# 1. Define agent with AgentObs.Sagents middleware
agent =
  Agent.new!(
    %{
      agent_id: "weather-agent",
      model: model,
      middleware: [AgentObs.Sagents],
      tools: [get_weather, get_time]
    },
    replace_default_middleware: true
  )

# 2. Execute with LangChain callbacks for inner span detail
{:ok, final_state} =
  Agent.execute(agent, state,
    callbacks: AgentObs.LangChain.callbacks()
  )
```

This produces the richest span tree:

```
AGENT: weather-agent
  LLM: anthropic/claude-sonnet-4-5-20250929 (tool-calling turn)
    TOOL: get_weather
    TOOL: get_time
  LLM: anthropic/claude-sonnet-4-5-20250929 (final answer)
```

## Context Propagation

OTel context is process-local. When spawning tasks, capture and restore it:

```elixir
parent_ctx = OpenTelemetry.Ctx.get_current()

Task.async(fn ->
  chain
  |> AgentObs.LangChain.instrument(parent_ctx: parent_ctx)
  |> LLMChain.run()
end)
```

The `callbacks/1` and `instrument/2` functions both accept `:parent_ctx`:

```elixir
# For callbacks passed to Sagents
parent_ctx = OpenTelemetry.Ctx.get_current()

Task.async(fn ->
  Agent.execute(agent, state,
    callbacks: AgentObs.LangChain.callbacks(parent_ctx: parent_ctx)
  )
end)
```

## Span Hierarchy Reference

### LangChain run/2 (single turn)

```
LLM: openai/gpt-4o
```

### LangChain run/2 (multi-turn with tools)

```
LLM: openai/gpt-4o (outer span from run/2)
  LLM: openai/gpt-4o (iteration 1: tool call)
    TOOL: lookup
  LLM: openai/gpt-4o (iteration 2: final answer)
```

### Sagents with LangChain callbacks

```
AGENT: my-agent (from Sagents middleware)
  LLM: anthropic/claude-... (from LangChain callbacks, iteration 1)
    TOOL: get_weather (from LangChain callbacks)
  LLM: anthropic/claude-... (from LangChain callbacks, iteration 2)
```

### Sagents with sub-agents

```
AGENT: orchestrator
  LLM: anthropic/claude-... (parent decides to delegate)
  AGENT: researcher (sub-agent)
    LLM: anthropic/claude-... (sub-agent's LLM call)
      TOOL: lookup
    LLM: anthropic/claude-... (sub-agent's final answer)
  LLM: anthropic/claude-... (parent summarizes)
```

## Best Practices

### 1. Place AgentObs.Sagents First in Middleware

The middleware captures timing in `before_model`. Placing it first ensures the
AGENT span covers the full pipeline duration including other middleware:

```elixir
# Good - AgentObs captures full timing
middleware: [
  AgentObs.Sagents,
  Sagents.Middleware.TodoList,
  Sagents.Middleware.FileSystem
]

# Bad - AgentObs misses time spent in TodoList
middleware: [
  Sagents.Middleware.TodoList,
  AgentObs.Sagents,
  Sagents.Middleware.FileSystem
]
```

### 2. Use instrument/2 for Chains Run Outside run/2

When a chain is managed by Sagents or your own loop, use `instrument/2` instead
of `run/2` to avoid double-wrapping:

```elixir
# Good - instrument/2 adds callbacks without wrapping execution
chain = AgentObs.LangChain.instrument(chain)

# Bad - run/2 wraps execution, conflicting with Sagents' own loop
AgentObs.LangChain.run(chain)  # Don't use inside Sagents
```

### 3. Pass Callbacks via Agent.execute for Sagents

Don't call `instrument/2` on the chain inside Sagents middleware. Instead, pass
callbacks through `Agent.execute/3`:

```elixir
# Good - callbacks applied at execution time
Agent.execute(agent, state,
  callbacks: AgentObs.LangChain.callbacks()
)

# Bad - instrument inside middleware creates coupling
# (the middleware doesn't control chain construction)
```

### 4. Use Metadata for Multi-Agent Identification

When running multiple agents, attach metadata to distinguish spans:

```elixir
Agent.execute(agent, state,
  callbacks: AgentObs.LangChain.callbacks(
    metadata: %{agent_name: "researcher", session_id: session_id}
  )
)
```

### 5. Model Name Extraction

`AgentObs.LangChain.extract_model_name/1` automatically infers the provider
from LangChain struct modules:

| Module | Extracted Name |
|---|---|
| `ChatAnthropic` | `"anthropic/claude-..."` |
| `ChatOpenAI` | `"openai/gpt-..."` |
| `ChatGoogleAI` | `"google/gemini-..."` |
| `ChatMistralAI` | `"mistral/..."` |
| `ChatOllamaAI` | `"ollama/..."` |

No manual model name configuration needed.

### 6. Disable Tool Tracing When Not Needed

If you only care about LLM spans and not individual tool executions:

```elixir
AgentObs.LangChain.callbacks(trace_tools: false)
```

This reduces span volume in high-throughput scenarios.

## Common Pitfalls

### 1. Using run/2 Inside Sagents

`run/2` wraps the chain execution in its own span and calls `LLMChain.run/2`
internally. Sagents already manages the chain execution loop, so using `run/2`
would double-execute the chain:

```elixir
# Wrong - run/2 calls LLMChain.run internally
defmodule MyMiddleware do
  def before_model(state, _config) do
    chain = build_chain(state)
    AgentObs.LangChain.run(chain)  # This runs the chain!
  end
end

# Right - use instrument/2 or callbacks/1
Agent.execute(agent, state,
  callbacks: AgentObs.LangChain.callbacks()
)
```

### 2. Forgetting Context Propagation in Tasks

OTel context doesn't automatically propagate to spawned processes:

```elixir
# Wrong - spans in the task have no parent
Task.async(fn ->
  Agent.execute(agent, state,
    callbacks: AgentObs.LangChain.callbacks()
  )
end)

# Right - capture and restore context
parent_ctx = OpenTelemetry.Ctx.get_current()
Task.async(fn ->
  Agent.execute(agent, state,
    callbacks: AgentObs.LangChain.callbacks(parent_ctx: parent_ctx)
  )
end)
```

### 3. Multiple instrument/2 Calls Stack Callbacks

Each call to `instrument/2` adds a new callback map. Calling it multiple times
produces duplicate spans:

```elixir
# Wrong - 3 callback maps, 3x the spans
chain
|> AgentObs.LangChain.instrument()
|> AgentObs.LangChain.instrument()
|> AgentObs.LangChain.instrument()

# Right - call once
chain
|> AgentObs.LangChain.instrument()
```

### 4. Not Handling Errors from run/2

`run/2` returns `{:error, chain, error}` on failure. Always pattern match:

```elixir
case AgentObs.LangChain.run(chain) do
  {:ok, updated_chain} ->
    # Success
    updated_chain

  {:error, _chain, error} ->
    # The span is still emitted with error status
    Logger.error("LLM call failed: #{inspect(error)}")
    {:error, error}
end
```

## Comparison: ReqLLM vs LangChain vs Sagents

| Feature | ReqLLM | LangChain | Sagents |
|---|---|---|---|
| **API Style** | Functional wrappers | Callback-based | Middleware behaviour |
| **Streaming** | Native support | Via LangChain | Via LangChain |
| **Tool Tracing** | Manual `trace_tool_execution/3` | Automatic via callbacks | Via LangChain callbacks |
| **Agent Spans** | Manual `trace_agent/3` | Not provided | Automatic via middleware |
| **Multi-Turn** | Manual loop | `while_needs_response` | Built-in agent loop |
| **Provider Support** | Any (via ReqLLM) | LangChain adapters | LangChain adapters |
| **Best For** | Direct API access, streaming-first | Chain-based workflows | Agent frameworks |

### When to Use Each

**Use ReqLLM** when:
- You want direct control over LLM API calls
- Streaming is a primary concern
- You're building a custom agent loop from scratch

**Use LangChain** when:
- You're already using LangChain's `LLMChain`
- You need callback-based instrumentation
- You want automatic tool tracing within chains

**Use Sagents** when:
- You're building multi-turn conversational agents
- You need middleware-based agent lifecycle management
- You want AGENT spans with automatic input/output capture

**Use LangChain + Sagents together** when:
- You want the richest possible span tree
- You need both AGENT lifecycle and per-LLM-call detail
- You're building production agents with sub-agent delegation

## Troubleshooting

### No spans appearing?

Verify the handler is attached:

```elixir
# Check in your test setup or application start
config :agent_obs,
  handlers: [AgentObs.Handlers.Phoenix]
```

### AGENT spans but no LLM/TOOL spans?

You're likely missing the LangChain callbacks. Pass them via
`Agent.execute/3`:

```elixir
Agent.execute(agent, state,
  callbacks: AgentObs.LangChain.callbacks()
)
```

### LLM spans but no TOOL spans?

Check that `trace_tools` is not disabled:

```elixir
# This disables tool tracing
AgentObs.LangChain.callbacks(trace_tools: false)

# Default enables it
AgentObs.LangChain.callbacks()
```

### Spans from different agents mixed in one trace?

Ensure each agent execution starts from its own trace root, or use metadata to
distinguish them:

```elixir
AgentObs.LangChain.callbacks(
  metadata: %{agent_name: "agent-1"}
)
```

### Token counts are zero?

Token usage comes from LangChain's `on_llm_token_usage` callback. Verify your
LLM adapter supports it. All major adapters (Anthropic, OpenAI, Google) report
token usage.

## Next Steps

- **[ReqLLM Integration](req_llm_integration.md)** - Streaming instrumentation
  with ReqLLM
- **[Instrumentation Guide](instrumentation.md)** - General patterns and best
  practices
- **[Custom Handlers](custom_handlers.md)** - Building custom observability
  backends
- **[Configuration](configuration.md)** - Advanced configuration options
