#let terms = (
  (
    slug: "term-agentobs-event",
    title: [AgentObs event],
    body: [A backend-neutral telemetry event whose name contains an event prefix, an operation type, and a lifecycle phase.],
  ),
  (
    slug: "term-event-prefix",
    title: [Event prefix],
    body: [The configurable atom list prepended to every AgentObs event name and used by handlers when attaching subscriptions.],
  ),
  (
    slug: "term-instrumentation-helper",
    title: [Instrumentation helper],
    body: [A public wrapper that executes an application operation while emitting its AgentObs event lifecycle.],
  ),
  (
    slug: "term-handler",
    title: [Handler],
    body: [A supervised telemetry subscriber that turns AgentObs events into records for an observability backend.],
  ),
  (
    slug: "term-span-context",
    title: [Span context],
    body: [The OpenTelemetry trace state that identifies a span and its parent relationship in the emitting process.],
  ),
  (
    slug: "term-openinference-attributes",
    title: [OpenInference attributes],
    body: [The AI-observability semantic fields used to describe agent, LLM, tool, chain, and prompt spans.],
  ),
  (
    slug: "term-reqllm-adapter",
    title: [ReqLLM adapter],
    body: [The optional integration that wraps ReqLLM calls and derives AgentObs metadata from their normalized responses.],
  ),
  (
    slug: "term-jido-tracer",
    title: [Jido tracer],
    body: [The optional Jido observability implementation that maps composer lifecycle callbacks directly to OpenTelemetry spans.],
  ),
)
