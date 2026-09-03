# Legacy roadmap preservation

Status: ready-for-human
Category: enhancement

## Problem

- The legacy `TODO.md`, retired after migration review, mixed completed implementation history with unresolved behavior decisions and future product ideas.
- Completed work is observable in the system and Git history. Unresolved work needs durable tracker homes before the checklist is removed.

## Preserved scope

- Resolve failure-event semantics, runtime reconfiguration, handler-owned exporter settings, Generic handler span kinds, and span-context lifecycle behavior for same-type nesting and callback failures.
- Resolve whether LLM stop events require output messages and whether ReqLLM streaming may buffer before returning.
- Improve documentation presentation with an ExDoc logo/theme, architecture diagram, and README status badges; add automatic Req and multi-backend examples.
- Measure telemetry overhead, document performance, evaluate asynchronous export, and emit AgentObs internal telemetry for handler lifecycle, processing time, export failures, and configuration errors.
- Add PII guidance, sensitive-field sanitization, configurable redaction, and a security-review checklist.
- Evaluate metrics, trace/log correlation, sampling by rate/error/cost, and custom attributes.
- Evaluate Phoenix LiveView, Plug, Ecto, Req retry/cache/rate-limit, and other automatic framework integrations.
- Evaluate a custom-handler DSL and reusable translation helpers.
- Evaluate Langfuse, Datadog, New Relic, Honeycomb, CloudWatch, and file-export handlers.
- Evaluate Mix tasks for configuration validation, handler connectivity, and local trace analysis, plus a local trace-viewing UI.
- Complete release checks, including measured coverage above 90%; record that the legacy Dialyzer check was superseded by the Elixir compiler gate; then evaluate package/release automation, announcements, download/feedback monitoring, contribution guidance, a code of conduct, and issue templates as independent work.
- Do not treat any item in this document as approved design. Each contract change requires owner review and a design-layer update first.
