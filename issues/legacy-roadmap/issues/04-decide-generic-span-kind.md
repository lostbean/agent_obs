# Decide Generic handler span kinds

Status: ready-for-human
Category: bug

- The Generic handler documentation says it uses standard OpenTelemetry span kinds.
- The implementation starts spans without setting a span kind.
- Decide the mapping for agent, LLM, tool, and prompt operations before changing emitted telemetry.

## Comments
