# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-02-18

### Added

- LangChain integration module (`AgentObs.LangChain`) with `run/2`,
  `instrument/2`, and `callbacks/1` for callback-based instrumentation.
- Sagents integration module (`AgentObs.Sagents`) implementing
  `Sagents.Middleware` for automatic agent lifecycle tracing.
- `AgentObs.LangChain.instrument/2` - Instruments a chain with AgentObs
  callbacks for use outside `run/2` (e.g., with Sagents or custom loops).
  Accepts `:parent_ctx`, `:trace_tools`, `:metadata`, and `:model` options.
- `callbacks/1` now accepts `:parent_ctx`, `:metadata`, and `:model` options for
  context propagation across `Task.async` boundaries and span enrichment.
- Per-iteration LLM child spans in `run/2` with `mode: :while_needs_response`
  for visibility into multi-turn agent loops.
- `input.value` attribute on LLM spans (last user message content) in the
  Phoenix handler for quick inspection in Arize Phoenix.
- `extract_model_name/1` is now a documented public function.
- `start_time` support in handlers for accurate span timing from Sagents.
- LangChain & Sagents integration guide (`guides/langchain_sagents.md`).
- E2E span tests covering ReqLLM, LangChain, and Sagents with cassettes.
- `AgentObs.MessageNormalizer` for shared message normalization across
  integrations.

### Changed

- `callbacks/1` now emits `[:agent_obs, :llm, :start]` /
  `[:agent_obs, :llm, :stop]` event pairs instead of standalone
  `[:agent_obs, :llm_token_usage]` and `[:agent_obs, :llm_message]` events. The
  old events were not consumed by any handler.
- Span storage in Phoenix and Generic handlers is now stack-based, supporting
  nested same-type spans (e.g., tool-within-tool).
- Handler stop/exception paths are wrapped in `try/after` to ensure OTel context
  is always restored even if the translator raises.

### Fixed

- Process dictionary leak in `LangChain.run/2` when `trace_llm/3` raises —
  collector key is now cleaned up in a `try/after` block.
- `System.monotonic_time()` calls now use explicit `:nanosecond` units for
  portable duration calculations.
- Provider extraction in Phoenix Translator now handles both `":"` (ReqLLM) and
  `"/"` (LangChain) model name separators.

## [0.1.0] - TBD

### Added

- First release
