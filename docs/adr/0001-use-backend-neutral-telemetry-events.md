# Instrumentation emits backend-neutral telemetry events

<a id="adr-0001"></a>

AgentObs must let applications change observability backends without changing instrumentation calls. The public helpers therefore emit a stable telemetry event vocabulary, and backend handlers translate those events into their own attribute conventions.
