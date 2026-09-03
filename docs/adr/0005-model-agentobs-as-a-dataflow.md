# AgentObs uses a dataflow model without domain entities

<a id="adr-0005"></a>

AgentObs transforms calls into events and events into trace spans without owning durable business identity or state. Its core model is therefore an instrumentation dataflow rather than an entity census.
