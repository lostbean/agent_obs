# Resolve failure-event semantics

Status: ready-for-human
Category: bug

- The legacy design says raised operations emit an `:exception` phase.
- The implementation rescues throws, exits, and exceptions inside the traced function and returns an error value to `:telemetry.span/3`, which produces a `:stop` phase carrying error metadata.
- Decide whether the intended public contract is exception propagation with an exception event or captured failure with a stop event before changing behavior.

## Comments
