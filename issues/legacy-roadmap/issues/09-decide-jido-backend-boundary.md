# Decide the Jido tracer backend boundary

Status: ready-for-human
Category: bug

- The recovered goal says AgentObs instrumentation avoids backend coupling.
- The Jido tracer calls the Phoenix translator and OpenTelemetry directly instead of emitting backend-neutral AgentObs events.
- Decide whether the goal excludes optional framework tracers or whether the Jido integration must cross the AgentObs event boundary.

## Comments
