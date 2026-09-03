# Each completed span restores its parent context

<a id="adr-0004"></a>

Nested agent, LLM, and tool operations must preserve their trace hierarchy. Each handler stores the started span with its parent context in the emitting process and restores the parent when the operation ends.
