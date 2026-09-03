# Decide LLM stop validation

Status: ready-for-human
Category: bug

- The legacy event schema requires output messages when a chat-model LLM event stops.
- The current validator accepts every LLM stop metadata map, including an empty map.
- Decide whether output messages are required, conditionally required by LLM type, or intentionally optional before changing validation.

## Comments
