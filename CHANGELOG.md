# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.7] - 2026-09-02

### Changed

- Restore the supported Elixir requirement to `~> 1.18` after validating the
  full suite on Elixir 1.18, 1.19, and 1.20 with compatible OTP releases.
- Update the optional ReqLLM requirement to `~> 1.21` and require Jido 2.3.3
  or later within the 2.x series.
- Refresh locked dependencies without changing application source files.

## [0.1.6] - 2026-06-17

### Changed

- Remove Dialyzer in favor of Elixir 1.20's built-in set-theoretic type checker.
  Drops the `dialyxir` dev dependency, the `dialyzer` project config, and the
  Dialyzer CI step; the type-check gate is now `mix compile --warnings-as-errors`.

## [0.1.5] - 2026-06-16

### Changed

- Target Elixir 1.20 / Erlang OTP 28 in the Nix dev environment.
- Bump all dependencies to their latest releases: `telemetry ~> 1.4`,
  `opentelemetry_api ~> 1.5`, `opentelemetry ~> 1.7`,
  `opentelemetry_exporter ~> 1.10`, `jason ~> 1.4`, `req_llm ~> 1.16`,
  `jido ~> 2.3`, `ex_doc ~> 0.40`, `dialyxir ~> 1.4`, `credo ~> 1.7`.
- Raise the minimum Elixir requirement to `~> 1.18`.

### Fixed

- `AgentObs.ReqLLM`: render multimodal content parts (`:file`/`:image`/`:audio`)
  in span attributes instead of dropping them to an empty string.
- The private model-string normalization helper in `AgentObs.ReqLLM`: a more specific
  `%{provider:, model:}` clause was unreachable, so provider-tagged models lost
  their `"provider:model"` formatting. Reordered the clauses so it applies.

## [0.1.4] - 2026-03-11

### Added

- `AgentObs.JidoTracer` — drop-in `Jido.Observe.Tracer` for automatic composer instrumentation
- Jido integration guide (`guides/jido_integration.md`)
- Jido integration section in README
- `jido ~> 2.0` as optional dependency

## [0.1.3] - 2026-03-08

### Added

- Initial implementation of AgentObs library
- Core telemetry API for agent, tool, LLM, and prompt instrumentation
- Phoenix handler with OpenInference semantic conventions
- Generic OpenTelemetry handler
- ReqLLM integration module with automatic streaming instrumentation
- Comprehensive test suite (11 files, 3,309 lines, 179 tests)
- Complete documentation with 5 detailed guides
- Demo application showcasing ReqLLM integration
- Enhanced guides with improved examples and troubleshooting


## [0.1.0] - TBD

### Added

- First release
