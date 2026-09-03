# Decide streaming completion semantics

Status: ready-for-human
Category: bug

- The legacy design describes ReqLLM streaming wrappers as preserving non-blocking streaming.
- The implementation consumes the source stream before returning a replay stream.
- Decide whether buffering is the intended contract or whether the adapter must return before the source stream completes.

## Comments
