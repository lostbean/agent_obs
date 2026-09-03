# Resolve handler exporter configuration

Status: ready-for-human
Category: bug

- The legacy design and module documentation show endpoint and authentication settings under handler-specific configuration.
- The handlers retain that configuration but export through the globally configured OpenTelemetry SDK and exporter.
- Decide whether AgentObs owns exporter configuration or only consumes a host-configured OpenTelemetry runtime.

## Comments
