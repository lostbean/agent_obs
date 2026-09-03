#import ".render/designlib.typ": *

#let title = [AgentObs — draft design]

#let body = [
  #section(
    title: "Foundation",
    lead: [This draft preserves the legacy design while separating confirmed implementation from unresolved intent, as recorded by #adr(6).],
    body: [
      #goal(title: "Instrument LLM agent operations without backend coupling", lens: "composition")[]

      #no-goal(title: "Couple instrumentation helpers to one observability backend")[]

      #invariant(
        title: "Instrumentation preserves the wrapped return value",
        enforcement: "mechanism",
        lens: "invariants",
      )[
        A valid #term("term-instrumentation-helper") returns the wrapped operation's result shape after adding telemetry metadata around it.
      ]

      #invariant(
        title: "Ordinary child completion restores its parent",
        enforcement: "mechanism",
        lens: "state",
      )[
        On the normal completion path, a handler restores the parent #term("term-span-context") after ending a nested operation of a different event type, as recorded by #adr(4). Same-type nesting and callback-failure cleanup remain unresolved.
      ]

      #principle(title: "Translate after the backend-neutral boundary", lens: "composition")[]
    ],
  )

  #pending-ledger(
    pending-entry(
          title: "Approve the migrated foundation",
          kind: "foundation",
          since: "2026-09-02",
    )[The goal, no-goal, and principle were recovered from the legacy design and require owner approval.],
    pending-entry(
          title: "Choose failure-event semantics",
          kind: "ruling",
          since: "2026-09-02",
    )[The legacy design requires exception events, while the implementation converts failures into stop events with error metadata. See #link("../../issues/legacy-roadmap/issues/01-resolve-failure-event-semantics.md")[issue 01].],
    pending-entry(
          title: "Choose runtime configuration semantics",
          kind: "ruling",
          since: "2026-09-02",
    )[Runtime environment updates do not restart handlers or prevent helpers from emitting events. See #link("../../issues/legacy-roadmap/issues/02-resolve-runtime-configuration.md")[issue 02].],
    pending-entry(
          title: "Choose exporter configuration ownership",
          kind: "ruling",
          since: "2026-09-02",
    )[Handler-specific endpoint settings are documented but the global OpenTelemetry exporter owns transport. See #link("../../issues/legacy-roadmap/issues/03-resolve-handler-exporter-configuration.md")[issue 03].],
    pending-entry(
          title: "Choose Generic handler span kinds",
          kind: "ruling",
          since: "2026-09-02",
    )[The documentation promises standard span kinds but the implementation leaves the OpenTelemetry kind at its default. See #link("../../issues/legacy-roadmap/issues/04-decide-generic-span-kind.md")[issue 04].],
    pending-entry(
          title: "Choose streaming completion semantics",
          kind: "ruling",
          since: "2026-09-02",
    )[The legacy design calls ReqLLM streaming non-blocking, while the adapter consumes the source stream before returning a replay stream. See #link("../../issues/legacy-roadmap/issues/07-decide-streaming-completion-semantics.md")[issue 07].],
    pending-entry(
      title: "Choose LLM stop validation",
      kind: "ruling",
      since: "2026-09-02",
    )[The legacy schema requires chat output messages, while the current validator accepts every LLM stop map. See #link("../../issues/legacy-roadmap/issues/08-decide-llm-stop-validation.md")[issue 08].],
    pending-entry(
      title: "Choose the Jido tracer backend boundary",
      kind: "ruling",
      since: "2026-09-02",
    )[The broad backend-neutral goal and the direct OpenTelemetry Jido integration need an owner-defined boundary. See #link("../../issues/legacy-roadmap/issues/09-decide-jido-backend-boundary.md")[issue 09].],
    pending-entry(
      title: "Choose span-context lifecycle semantics",
      kind: "ruling",
      since: "2026-09-02",
    )[Same-type nesting can overwrite an outer handler context, and callback failures can skip restoration. See #link("../../issues/legacy-roadmap/issues/10-decide-span-context-lifecycle.md")[issue 10].],
  )

  #section(
    title: "System at a glance",
    lead: "AgentObs is one instrumentation context with optional framework adapters and two trace translations.",
    visual: diagram(
      altitude: "L2",
      title: "calls become events and spans",
      nodes: (
        (id: "host", label: "host operation", external: true),
        (id: "api", label: "instrumentation helpers", tint: "teal"),
        (id: "events", label: "emitted AgentObs events", tint: "teal"),
      ),
      edges: (
        ("host", "api", "wraps"),
        ("api", "events", "emits"),
      ),
    ),
    body: [
      The #term("term-reqllm-adapter") enters through the public helpers. The #term("term-jido-tracer") is a separate adapter that creates OpenTelemetry spans from Jido callbacks without emitting AgentObs events.

      #diagram(
        altitude: "L2",
        title: "events fan out to configured trace translations",
        nodes: (
          (id: "events", label: "subscribed AgentObs events", tint: "teal"),
          (id: "phoenix", label: "Phoenix handler", tint: "violet"),
          (id: "generic", label: "Generic handler", tint: "blue"),
          (id: "otel", label: "OpenTelemetry runtime", external: true),
        ),
        edges: (
          ("events", "phoenix", "subscribed"),
          ("events", "generic", "subscribed"),
          ("phoenix", "otel", "creates spans"),
          ("generic", "otel", "creates spans"),
        ),
      )

      The system has no durable domain entities because it transforms application calls into telemetry and trace data. #adr(5) records this modeling boundary.
    ],
  )

  #pagebreak()

  #section(
    title: "Instrumentation core",
    lead: [The core validates operation metadata, executes application code, and emits the backend-neutral lifecycle chosen in #adr(1).],
    body: [
      #components(
        component(
          name: "Public instrumentation API",
          mission: "Wrap the four validated operation lifecycles and emit discrete custom events.",
          answers: answers-data(
            responsibility: [Merge operation identity into caller metadata and invoke wrapped functions; `emit/2` sends a custom event outside those four span lifecycles.],
            interface: [`trace_agent/3`, `trace_tool/3`, `trace_llm/3`, `trace_prompt/3`, `emit/2`, and `configure/1`.],
            interactions: [Valid helpers call the event schema before `:telemetry.span/3`; custom emission calls `:telemetry.execute/3`.],
            invariants: [The wrapped return shape is preserved for successful, error, and unrecognized values.],
            failure: [Invalid start metadata logs a warning and runs the function without span events. Raised, thrown, and exited failures are currently converted to error values.],
          ),
        ),
        component(
          name: "Event schema",
          mission: "Define the metadata contract shared by emitters and handlers.",
          answers: answers-data(
            responsibility: [Validate required start and stop fields and normalize LLM message roles.],
            interface: [`validate_event/3`, `normalize_metadata/3`, `event_types/0`, and `event_phases/0`.],
            interactions: [Instrumentation helpers validate before emission; translators consume the emitted metadata.],
            invariants: [Supported operation types are agent, tool, LLM, and prompt; supported phases are start, stop, and exception.],
            failure: [Unsupported types, phases, or required fields return a descriptive error tuple.],
          ),
        ),
      )

      #components(
        component(
          name: "Agent event contract",
          mission: "Describe an agent loop or invocation.",
          answers: answers-data(
            responsibility: [Carry agent identity, input, output, and optional execution context.],
            interface: [`[:prefix, :agent, :start | :stop | :exception]`.],
            interactions: [Start requires `name` and `input`; it may include `model`, `session_id`, `user_id`, and custom `metadata`. Stop requires `output`; it may include tools, iterations, tokens, cost, and custom metadata.],
            invariants: [The configured event prefix precedes the operation type and lifecycle phase.],
            failure: [Exception metadata is accepted without required fields; helper-captured failures currently reach stop metadata instead.],
          ),
        ),
        component(
          name: "Tool event contract",
          mission: "Describe one tool execution.",
          answers: answers-data(
            responsibility: [Carry the tool identity, arguments, optional description, and result.],
            interface: [`[:prefix, :tool, :start | :stop | :exception]`.],
            interactions: [Start requires `name` and `arguments`; stop requires `result`. Arguments may be a map or encoded string.],
            invariants: [Tool inputs and outputs remain backend-neutral event values until a handler translates them.],
            failure: [Exception metadata has no required fields; invalid start or stop metadata prevents instrumentation but not execution.],
          ),
        ),
      )

      #pagebreak()

      #components(
        component(
          name: "LLM event contract",
          mission: "Describe a chat, completion, or embedding request.",
          answers: answers-data(
            responsibility: [Carry model inputs, invocation parameters, outputs, token use, cost, and finish reason.],
            interface: [`[:prefix, :llm, :start | :stop | :exception]`.],
            interactions: [Start requires `model`; chat is the default type and also requires `input_messages`. Optional request fields include type, temperature, maximum tokens, top-p, top-k, penalties, and custom metadata. Stop may carry output messages, prompt/completion/total tokens, cost, and finish reason.],
            invariants: [Message roles expressed as atoms normalize to strings; valid explicit types are chat, completion, and embedding.],
            failure: [The current validator accepts any stop map, while the legacy contract requires chat output messages; #link("../../issues/legacy-roadmap/issues/08-decide-llm-stop-validation.md")[issue 08] holds the ruling.],
          ),
        ),
        component(
          name: "Prompt event contract",
          mission: "Describe prompt-template rendering.",
          answers: answers-data(
            responsibility: [Carry a template name, input variables, optional template text, and rendered output.],
            interface: [`[:prefix, :prompt, :start | :stop | :exception]`.],
            interactions: [Start requires `name` and `variables`; stop requires `rendered`.],
            invariants: [Prompt rendering remains a validated lifecycle even though Phoenix translates its span kind as CHAIN.],
            failure: [Exception metadata has no required fields; missing required metadata returns a descriptive validation error.],
          ),
        ),
      )

      #behavior(
        title: "Valid instrumentation emits one completed lifecycle",
        area: "Valid public instrumentation",
        level: "boundary",
      )[
        #given[The start metadata satisfies the event schema.]
        #when[A caller executes an instrumentation helper.]
        #then[A start event precedes the wrapped operation.]
        #then[A stop event follows the wrapped operation with derived result metadata.]
        #then[The caller receives the wrapped operation's result shape.]
      ]

      #behavior(
        title: "Invalid metadata leaves the operation uninstrumented",
        area: "Invalid public instrumentation",
        level: "boundary",
      )[
        #given[The start metadata does not satisfy the event schema.]
        #when[A caller invokes a helper with invalid metadata.]
        #then[The operation runs once without lifecycle events.]
        #then[A warning describes the validation failure.]
      ]
    ],
  )

  #pagebreak()

  #section(
    title: "Handler pipeline",
    lead: [Supervised handlers subscribe synchronously and maintain nested span context in the emitting process, following #adr(2).],
    body: [
      #components(
        component(
          name: "Handler supervision",
          mission: "Start each configured backend subscriber independently.",
          answers: answers-data(
            responsibility: [Start configured handler modules under a one-for-one supervisor when the application is enabled.],
            interface: [The application environment supplies `enabled`, `handlers`, the event prefix, and handler-specific maps.],
            interactions: [The application starts the supervisor; the supervisor calls each handler's child specification.],
            invariants: [One handler restart does not restart its peers.],
            failure: [A handler that cannot attach fails its child start and follows ordinary supervisor restart behavior.],
          ),
        ),
        component(
          name: "Phoenix handler and translator",
          mission: "Create OpenInference-compatible spans from AgentObs events.",
          answers: answers-data(
            responsibility: [Translate event metadata to #term("term-openinference-attributes") and manage the corresponding span lifecycle.],
            interface: [The handler callbacks attach, handle an event, and detach; the translator maps start, stop, and exception metadata.],
            interactions: [Observed implementation: the handler calls the pure translator and the host-configured OpenTelemetry runtime. Handler-specific exporter settings remain an unresolved legacy contract.],
            invariants: [On normal completion, nesting across different event types restores the parent context; each event type uses one process-dictionary key.],
            failure: [Unexpected handler errors are logged and suppressed so telemetry callbacks return `:ok`; missing active spans produce warnings. Same-type nesting and restoration after callback failures remain pending.],
          ),
        ),
      )

      #pagebreak()

      #components(
        component(
          name: "Generic handler",
          mission: "Create backend-neutral OpenTelemetry spans with simplified attributes.",
          answers: answers-data(
            responsibility: [Map AgentObs metadata to basic input, output, duration, token, and cost attributes.],
            interface: [The same handler callbacks and event subscription surface as the Phoenix handler.],
            interactions: [Observed implementation: it writes spans through the host-configured OpenTelemetry runtime without the Phoenix translator. Exporter ownership remains pending.],
            invariants: [The ordinary completion path reinstates a parent when nested operations use distinct event types; the handler holds one process-dictionary slot for each type.],
            failure: [Encoding falls back to inspected text; callback errors are logged and suppressed; missing active spans produce warnings. Recursive same-type nesting and cleanup after callback failure remain pending.],
          ),
        ),
      )

      #notes(title: "Observed Phoenix attribute mapping")[
        - Agent start maps to `openinference.span.kind=AGENT`, `input.value`, text MIME type, optional `llm.model_name`, session/user fields, and flattened custom metadata. Agent stop maps `output.value`, indexed tools, iterations, token counts, cost, and latency.
        - Tool start maps to `openinference.span.kind=TOOL`, `tool.name`, `tool.description`, `input.value`, and encoded `tool.parameters`. Tool stop maps `output.value` and latency.
        - LLM start maps to `openinference.span.kind=LLM`, `llm.model_name`, provider fields, invocation parameters, AI SDK identifiers, and flattened input messages. LLM stop maps flattened output messages, `llm.token_count.prompt`, `llm.token_count.completion`, total tokens, `llm.cost.total`, finish reasons, `output.value`, and latency.
        - Prompt start maps to `openinference.span.kind=CHAIN`, encoded variables, and optional template fields. Prompt stop maps rendered output and latency.
        - A message at index `N` uses `llm.input_messages.N.message.role` or the corresponding output path. A tool call at index `M` appends `.message.tool_calls.M.tool_call.function.name` and `.function.arguments`.
        - Exception translation maps type, message, escaped status, optional stacktrace, and latency; whether helpers emit exception events remains pending.
      ]

      The #term("term-handler") callback runs synchronously in the process emitting the AgentObs event. Expensive translation or export work therefore affects that process until the OpenTelemetry runtime accepts the span.
    ],
  )

  #section(
    title: "Framework adapters",
    lead: [Optional adapters keep framework-specific shapes outside the core event contract; #adr(3) records the ReqLLM boundary choice.],
    body: [
      #components(
        component(
          name: "ReqLLM adapter",
          mission: "Instrument text, object, stream, and tool operations exposed by ReqLLM.",
          answers: answers-data(
            responsibility: [Derive messages, usage, finish reason, objects, and tool calls from ReqLLM results.],
            interface: [Text and object generation wrappers, streaming wrappers, tool execution, and stream collection helpers.],
            interactions: [It calls ReqLLM and routes derived metadata through the public AgentObs helpers.],
            invariants: [The returned response remains a ReqLLM response shape and collected usage defaults missing token counts to zero.],
            failure: [Non-bang calls return ReqLLM error tuples; bang calls raise; malformed tool-argument fragments become an empty map.],
          ),
        ),
        component(
          name: "Jido tracer",
          mission: "Translate Jido composer callbacks into nested OpenTelemetry spans.",
          answers: answers-data(
            responsibility: [Classify composer agent, LLM, tool, and iteration callbacks and translate their metadata.],
            interface: [`span_start/2`, `span_stop/2`, and `span_exception/4` implement the Jido tracer behaviour.],
            interactions: [It uses the Phoenix translator and OpenTelemetry directly rather than the AgentObs event bus.],
            invariants: [The returned tracer context contains the span and parent context required to finish or restore the trace.],
            failure: [Nil span contexts are accepted as no-ops; exception callbacks record the failure and restore the parent context only when the callback reaches its normal cleanup path.],
          ),
        ),
      )

      #notes(title: "Observed streaming behavior")[
        The current ReqLLM streaming wrappers consume the source stream to completion before returning a replay stream. The legacy design describes preserved non-blocking streaming, so the pending ruling keeps that discrepancy explicit.
      ]
    ],
  )

  #section(
    title: "End-to-end walkthrough",
    lead: "A traced LLM call crosses the public boundary, event bus, selected handlers, and the host's exporter.",
    visual: sequence(
      title: "one traced operation",
      participants: (
        (id: "host", label: "Host", shape: "actor"),
        (id: "api", label: "AgentObs", shape: "control"),
        (id: "handler", label: "Handler", shape: "control"),
        (id: "otel", label: "OpenTelemetry", shape: "boundary"),
      ),
      steps: (
        seq-msg("host", "api", "call helper"),
        seq-msg("api", "handler", "start event"),
        seq-msg("handler", "otel", "start span"),
        seq-msg("api", "host", "execute operation"),
        seq-msg("api", "handler", "stop event"),
        seq-msg("handler", "otel", "finish span"),
        seq-msg("api", "host", "return result"),
      ),
    ),
    body: [
      The handler attaches the new span to the current process before the wrapped operation runs. Nested instrumentation across different event types therefore inherits the active span, and ordinary child completion restores its parent before the outer operation continues. Same-type nesting and cleanup after callback failures are pending in issue 10.
    ],
  )
]
