# ReqLLM integration wraps its public API

<a id="adr-0003"></a>

ReqLLM already normalizes providers, streaming chunks, usage, and tool calls. AgentObs wraps ReqLLM operations instead of adding low-level Req middleware, so instrumentation reuses those normalized results.
