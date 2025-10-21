# AgentObs Implementation Checklist

## Phase 1: Project Setup and Core Infrastructure

### 1.1 Project Initialization

- [ ] Run `mix new agent_obs --sup` to create supervised application
- [ ] Configure `mix.exs` with project metadata
  - [ ] Add description and package configuration
  - [ ] Set Elixir version requirement (~> 1.14)
  - [ ] Add license (Apache 2.0)
  - [ ] Configure for Hex publishing
- [ ] Add core dependencies to `mix.exs`:
  - [ ] `{:telemetry, "~> 1.0"}`
  - [ ] `{:opentelemetry_api, "~> 1.2"}`
  - [ ] `{:opentelemetry, "~> 1.3"}`
  - [ ] `{:opentelemetry_exporter, "~> 1.6"}`
  - [ ] `{:jason, "~> 1.2"}`
- [ ] Add development dependencies:
  - [ ] `{:ex_doc, "~> 0.28", only: :dev, runtime: false}`
  - [ ] `{:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false}`
  - [ ] `{:credo, "~> 1.6", only: [:dev, :test], runtime: false}`
- [ ] Initialize git repository
- [ ] Create `.gitignore` file
- [ ] Create `README.md` with basic project description

### 1.2 Project Structure

- [ ] Create directory structure:
  ```
  lib/
  ├── agent_obs.ex
  ├── agent_obs/
  │   ├── application.ex
  │   ├── supervisor.ex
  │   ├── events.ex
  │   ├── req.ex
  │   ├── handler.ex
  │   └── handlers/
  │       ├── phoenix.ex
  │       ├── phoenix/
  │       │   └── translator.ex
  │       └── generic.ex
  test/
  ├── test_helper.exs
  └── agent_obs/
      ├── events_test.exs
      ├── handler_contract_test.exs
      ├── integration_test.exs
      ├── multi_backend_test.exs
      └── handlers/
          └── phoenix/
              └── translator_test.exs
  ```

### 1.3 CI/CD Setup

- [ ] Create `.github/workflows/ci.yml` for GitHub Actions
  - [ ] Run tests on multiple Elixir/OTP versions
  - [ ] Run `mix format --check-formatted`
  - [ ] Run `mix credo --strict`
  - [ ] Run `mix dialyzer`
  - [ ] Generate and upload coverage reports
- [ ] Create `.github/workflows/publish.yml` for Hex publishing
- [ ] Add status badges to README.md

## Phase 2: Core Event Schema (Layer 1)

### 2.1 AgentObs.Events Module

- [ ] Create `lib/agent_obs/events.ex`
- [ ] Define event type constants:
  - [ ] `@event_types [:agent, :tool, :llm, :prompt]`
  - [ ] `@event_phases [:start, :stop, :exception]`
- [ ] Implement `validate_event/3` for each event type:
  - [ ] Agent event validation (required: name, input)
  - [ ] Tool event validation (required: name, arguments)
  - [ ] LLM event validation (required: model, input_messages)
  - [ ] Prompt event validation (required: name, variables)
- [ ] Implement `normalize_metadata/3`:
  - [ ] Convert atom keys to strings where needed
  - [ ] Normalize role atoms to strings
  - [ ] Handle both map and JSON string formats
- [ ] Add `@type` specs for all event metadata structures
- [ ] Write comprehensive documentation with examples

### 2.2 AgentObs Module (Public API)

- [ ] Create `lib/agent_obs.ex`
- [ ] Implement `trace_agent/3`:
  - [ ] Wrap logic in `:telemetry.span/3`
  - [ ] Emit `[:agent_obs, :agent, :start | :stop | :exception]`
  - [ ] Handle function return value formats
  - [ ] Add proper error handling
- [ ] Implement `trace_tool/3`:
  - [ ] Similar structure to `trace_agent/3`
  - [ ] Emit `[:agent_obs, :tool, ...]` events
  - [ ] Support both map and JSON arguments
- [ ] Implement `trace_llm/3`:
  - [ ] Emit `[:agent_obs, :llm, ...]` events
  - [ ] Extract token/cost metadata from return value
- [ ] Implement `trace_prompt/3`:
  - [ ] Emit `[:agent_obs, :prompt, ...]` events
- [ ] Implement `emit/2` for low-level custom events
- [ ] Implement `configure/1` for runtime configuration
- [ ] Add comprehensive `@moduledoc` and `@doc` for all functions
- [ ] Add `@spec` type specifications
- [ ] Add usage examples in documentation

## Phase 3: Handler Infrastructure (Layer 2)

### 3.1 AgentObs.Handler Behaviour

- [ ] Create `lib/agent_obs/handler.ex`
- [ ] Define behaviour with callbacks:
  - [ ] `@callback attach(config :: map()) :: {:ok, term()} | {:error, term()}`
  - [ ] `@callback handle_event(event_name, measurements, metadata, config) :: :ok`
  - [ ] `@callback detach(state :: term()) :: :ok`
- [ ] Add comprehensive behaviour documentation
- [ ] Define expected config structure
- [ ] Document synchronous execution guarantees

### 3.2 AgentObs.Supervisor

- [ ] Create `lib/agent_obs/supervisor.ex`
- [ ] Implement `start_link/1`
- [ ] Implement `init/1`:
  - [ ] Read `:handlers` from application config
  - [ ] Read `:enabled` flag
  - [ ] Start configured handler children
  - [ ] Use `:one_for_one` strategy
- [ ] Add `get_handler_config/1` private helper
- [ ] Handle missing or invalid configuration gracefully

### 3.3 AgentObs.Application

- [ ] Update `lib/agent_obs/application.ex`
- [ ] Implement `start/2`:
  - [ ] Check `:enabled` config flag
  - [ ] Start `AgentObs.Supervisor` if enabled
  - [ ] Log startup information at debug level
- [ ] Add graceful shutdown in `stop/1`

## Phase 4: Phoenix Handler (Arize Phoenix Backend)

### 4.1 Phoenix Translator

- [ ] Create `lib/agent_obs/handlers/phoenix/translator.ex`
- [ ] Implement `from_start_metadata/2` for each event type:
  - [ ] `:agent` → OpenInference AGENT span
  - [ ] `:tool` → OpenInference TOOL span
  - [ ] `:llm` → OpenInference LLM span
  - [ ] `:prompt` → Custom span kind
- [ ] Implement `from_stop_metadata/3` for each event type
- [ ] Implement `from_exception_metadata/3`
- [ ] Implement message flattening helpers:
  - [ ] `flatten_input_messages/1`
  - [ ] `flatten_output_messages/1`
  - [ ] `flatten_tool_calls/2`
  - [ ] `flatten_tool_arguments/1`
- [ ] Implement `maybe_add/3` helper
- [ ] Implement `add_duration/2` helper
- [ ] Add comprehensive unit tests
- [ ] Validate against OpenInference spec

### 4.2 Phoenix Handler

- [ ] Create `lib/agent_obs/handlers/phoenix.ex`
- [ ] Implement GenServer callbacks:
  - [ ] `start_link/1`
  - [ ] `init/1` - attach to all event types
  - [ ] `terminate/2` - detach from events
- [ ] Implement `AgentObs.Handler` behaviour:
  - [ ] `attach/1` - use `:telemetry.attach_many/4`
  - [ ] `handle_event/4` - dispatch to private handlers
  - [ ] `detach/1` - clean up telemetry attachments
- [ ] Implement private event handlers:
  - [ ] `handle_start/2` - create and store span context
  - [ ] `handle_stop/3` - add attributes and end span
  - [ ] `handle_exception/3` - record exception and end span
- [ ] Implement span context management:
  - [ ] Store in process dictionary with unique key
  - [ ] Retrieve and clean up properly
- [ ] Add error handling for missing span context
- [ ] Read configuration from `:agent_obs, AgentObs.Handlers.Phoenix`
- [ ] Log handler lifecycle at debug level

### 4.3 OpenTelemetry Configuration Helper

- [ ] Create documentation for OTel SDK configuration
- [ ] Provide example `config/runtime.exs` snippets
- [ ] Document required environment variables:
  - [ ] `ARIZE_PHOENIX_OTLP_ENDPOINT`
  - [ ] `ARIZE_PHOENIX_API_KEY`
- [ ] Document resource attributes configuration
- [ ] Document batch processor configuration

## Phase 5: Generic Handler (Basic OpenTelemetry)

### 5.1 Generic Handler Implementation

- [ ] Create `lib/agent_obs/handlers/generic.ex`
- [ ] Implement GenServer structure (similar to Phoenix handler)
- [ ] Implement `AgentObs.Handler` behaviour
- [ ] Implement simplified attribute translation:
  - [ ] Basic span naming
  - [ ] Simple key-value attributes (no OpenInference)
  - [ ] Standard OTel attributes (input.value, output.value)
- [ ] No message flattening or complex transformations
- [ ] Add configuration support
- [ ] Add tests

## Phase 6: Req Integration

### 6.1 AgentObs.Req Module

- [ ] Create `lib/agent_obs/req.ex`
- [ ] Implement `attach/1` - returns Req client with middleware
- [ ] Create request middleware:
  - [ ] Detect LLM API calls (OpenAI, Anthropic, etc.)
  - [ ] Extract request parameters (model, messages, etc.)
  - [ ] Emit `[:agent_obs, :llm, :start]` event
- [ ] Create response middleware:
  - [ ] Extract response data (messages, tokens, etc.)
  - [ ] Calculate cost based on model pricing
  - [ ] Emit `[:agent_obs, :llm, :stop]` event
- [ ] Handle errors and exceptions
- [ ] Support for multiple LLM providers:
  - [ ] OpenAI API format
  - [ ] Anthropic API format
  - [ ] Detect provider from base_url
- [ ] Add comprehensive tests with mocked HTTP
- [ ] Document usage patterns

### 6.2 Req Integration Tests

- [ ] Test with `req_llm` library
- [ ] Mock OpenAI API responses
- [ ] Verify automatic event emission
- [ ] Test token counting extraction
- [ ] Test cost calculation

## Phase 7: Testing Infrastructure

### 7.1 Test Helpers and Setup

- [ ] Create `test/support/test_helpers.ex`:
  - [ ] In-memory OTel exporter for testing
  - [ ] Helper to capture emitted spans
  - [ ] Helper to assert span attributes
  - [ ] Helper to assert span hierarchy
- [ ] Configure test environment in `config/test.exs`:
  - [ ] Disable automatic handler startup
  - [ ] Configure test exporter
- [ ] Update `test/test_helper.exs`:
  - [ ] Start required applications
  - [ ] Configure telemetry test mode

### 7.2 Unit Tests: Event Schema

- [ ] Create `test/agent_obs/events_test.exs`
- [ ] Test validation for all event types:
  - [ ] Valid metadata passes
  - [ ] Invalid metadata returns errors
  - [ ] Missing required fields detected
- [ ] Test normalization:
  - [ ] Atom to string conversion
  - [ ] Type coercion
  - [ ] Nested structure handling

### 7.3 Unit Tests: Phoenix Translator

- [ ] Create `test/agent_obs/handlers/phoenix/translator_test.exs`
- [ ] Test `from_start_metadata/2` for all event types
- [ ] Test `from_stop_metadata/3` for all event types
- [ ] Test message flattening:
  - [ ] Single message
  - [ ] Multiple messages
  - [ ] Messages with tool calls
  - [ ] Nested tool call arguments
- [ ] Test edge cases:
  - [ ] Empty lists
  - [ ] Nil values
  - [ ] Invalid JSON in tool calls
- [ ] Verify OpenInference spec compliance

### 7.4 Contract Tests: Handler Behaviour

- [ ] Create `test/agent_obs/handler_contract_test.exs`
- [ ] Test all handlers implement behaviour correctly
- [ ] Test `attach/1` returns valid state
- [ ] Test `handle_event/4` is callable
- [ ] Test `detach/1` cleans up properly
- [ ] Use property-based testing if applicable

### 7.5 Integration Tests

- [ ] Create `test/agent_obs/integration_test.exs`
- [ ] Test complete flow: `trace_agent/3` → OTel span
- [ ] Test nested spans (agent → llm → tool)
- [ ] Test span context propagation
- [ ] Test parent-child relationships
- [ ] Test error handling and exception spans
- [ ] Test duration measurement
- [ ] Test async operation (if implemented)

### 7.6 Multi-Backend Tests

- [ ] Create `test/agent_obs/multi_backend_test.exs`
- [ ] Test Phoenix handler produces OpenInference spans
- [ ] Test Generic handler produces basic OTel spans
- [ ] Test multiple handlers running simultaneously
- [ ] Test handler isolation (no cross-contamination)
- [ ] Test per-handler configuration

### 7.7 Req Integration Tests

- [ ] Create `test/agent_obs/req_test.exs`
- [ ] Mock LLM API responses with Bypass or similar
- [ ] Test automatic event emission
- [ ] Test token/cost extraction
- [ ] Test multi-provider support
- [ ] Test error handling

## Phase 8: Documentation

### 8.1 Module Documentation

- [ ] Comprehensive `@moduledoc` for all modules
- [ ] `@doc` for all public functions
- [ ] `@spec` type specifications everywhere
- [ ] Usage examples in all public function docs
- [ ] Document configuration options

### 8.2 Guides

- [ ] Create `guides/getting_started.md`:
  - [ ] Installation
  - [ ] Basic configuration
  - [ ] First instrumentation
  - [ ] Viewing traces in Phoenix
- [ ] Create `guides/configuration.md`:
  - [ ] Core configuration options
  - [ ] Phoenix handler configuration
  - [ ] Generic handler configuration
  - [ ] Environment-specific setup
  - [ ] Multiple backend setup
- [ ] Create `guides/instrumentation.md`:
  - [ ] Using high-level helpers
  - [ ] Custom event emission
  - [ ] Nested instrumentation
  - [ ] Best practices
- [ ] Create `guides/req_integration.md`:
  - [ ] Automatic LLM instrumentation
  - [ ] Provider support
  - [ ] Custom configuration
- [ ] Create `guides/backends.md`:
  - [ ] Arize Phoenix setup
  - [ ] Generic OTel setup
  - [ ] Creating custom backends
  - [ ] Handler behaviour implementation

### 8.3 API Reference

- [ ] Generate with ExDoc
- [ ] Configure logo and theme
- [ ] Add code examples throughout
- [ ] Link to external resources (OpenInference spec, etc.)

### 8.4 README.md

- [ ] Project description and goals
- [ ] Key features list
- [ ] Quick start example
- [ ] Installation instructions
- [ ] Configuration example
- [ ] Link to full documentation
- [ ] Architecture diagram
- [ ] Contributing guidelines
- [ ] License information

### 8.5 CHANGELOG.md

- [ ] Create initial CHANGELOG.md
- [ ] Follow Keep a Changelog format
- [ ] Document all versions

## Phase 9: Examples and Demo Application

### 9.1 Example Agent

- [ ] Create `examples/weather_agent/` directory
- [ ] Implement weather agent with:
  - [ ] LLM call for tool selection
  - [ ] Tool execution (weather API)
  - [ ] Final response generation
- [ ] Full instrumentation with `AgentObs`
- [ ] README with setup instructions
- [ ] Docker Compose for local Phoenix instance

### 9.2 Req Integration Example

- [ ] Create `examples/req_llm_demo/`
- [ ] Show automatic instrumentation
- [ ] Multiple LLM providers
- [ ] Comparison with manual instrumentation

### 9.3 Multi-Backend Example

- [ ] Create `examples/multi_backend/`
- [ ] Configure both Phoenix and Generic handlers
- [ ] Show same instrumentation → different outputs
- [ ] Demonstrate backend switching

## Phase 10: Production Readiness

### 10.1 Performance Optimization

- [ ] Benchmark telemetry overhead
- [ ] Optimize translator for minimal allocations
- [ ] Consider async export option (if needed)
- [ ] Add telemetry event for AgentObs itself (meta-observability)
- [ ] Document performance characteristics

### 10.2 Error Handling

- [ ] Graceful degradation if handler crashes
- [ ] Proper error logging without crashing app
- [ ] Validate configuration at startup
- [ ] Handle missing dependencies gracefully
- [ ] Add telemetry for internal errors

### 10.3 Security

- [ ] Sanitize sensitive data in events
- [ ] Document PII handling best practices
- [ ] Secure API key configuration
- [ ] Add option to redact specific fields
- [ ] Security audit checklist

### 10.4 Observability

- [ ] Add internal telemetry events:
  - [ ] Handler attach/detach
  - [ ] Event processing time
  - [ ] Export failures
  - [ ] Configuration errors
- [ ] Document internal observability

## Phase 11: Release Preparation

### 11.1 Pre-Release Checklist

- [ ] All tests passing
- [ ] 100% documentation coverage
- [ ] No Dialyzer warnings
- [ ] Credo passes with no issues
- [ ] Code coverage > 90%
- [ ] All examples working
- [ ] Security review completed
- [ ] Performance benchmarks documented

### 11.2 Package Publishing

- [ ] Configure `mix.exs` for Hex:
  - [ ] package/0 function with files, licenses, links
  - [ ] Proper version number (start with 0.1.0)
- [ ] Publish to Hex.pm:
  - [ ] `mix hex.publish`
- [ ] Create GitHub release
- [ ] Tag version in git

### 11.3 Announcement

- [ ] Blog post about the library
- [ ] Post on Elixir Forum
- [ ] Tweet announcement
- [ ] Submit to Elixir Radar newsletter
- [ ] Add to awesome-elixir list

## Phase 12: Post-Release

### 12.1 Monitoring

- [ ] Monitor Hex downloads
- [ ] Watch GitHub issues and discussions
- [ ] Monitor Elixir Forum mentions
- [ ] Collect user feedback

### 12.2 Community Building

- [ ] Respond to issues promptly
- [ ] Review and merge PRs
- [ ] Create contributing guidelines
- [ ] Add code of conduct
- [ ] Create issue templates

### 12.3 Roadmap

- [ ] Plan v0.2.0 features:
  - [ ] Additional handlers (Langfuse, Datadog, etc.)
  - [ ] Metrics support (in addition to traces)
  - [ ] Logs correlation
  - [ ] Sampling strategies
  - [ ] Custom attributes support
  - [ ] Automatic Phoenix framework instrumentation
- [ ] Gather community feedback
- [ ] Prioritize feature requests

## Future Enhancements (Post v1.0)

### Advanced Features

- [ ] Automatic framework integration:
  - [ ] Phoenix LiveView instrumentation
  - [ ] Plug pipeline instrumentation
  - [ ] Ecto query instrumentation (as context)
- [ ] Sampling strategies:
  - [ ] Rate-based sampling
  - [ ] Error-based sampling
  - [ ] Cost-based sampling
- [ ] Metrics collection:
  - [ ] Token usage histograms
  - [ ] Cost tracking
  - [ ] Latency percentiles
- [ ] Log correlation:
  - [ ] Inject trace IDs into Logger metadata
  - [ ] Connect logs to spans
- [ ] Advanced Req integration:
  - [ ] Retry instrumentation
  - [ ] Cache hit/miss tracking
  - [ ] Rate limit detection
- [ ] DSL for custom handlers:
  - [ ] Simplify handler creation
  - [ ] Reusable transformation helpers

### Additional Backends

- [ ] Langfuse handler
- [ ] Datadog handler
- [ ] New Relic handler
- [ ] Honeycomb handler
- [ ] CloudWatch handler
- [ ] Custom CSV/JSON file export handler

### Tooling

- [ ] Mix task to validate configuration
- [ ] Mix task to test handler connectivity
- [ ] Mix task to analyze trace data locally
- [ ] Development UI for local trace viewing

---

## Progress Tracking

**Phase Status:**

- [ ] Phase 1: Project Setup (0/X tasks)
- [ ] Phase 2: Core Event Schema (0/X tasks)
- [ ] Phase 3: Handler Infrastructure (0/X tasks)
- [ ] Phase 4: Phoenix Handler (0/X tasks)
- [ ] Phase 5: Generic Handler (0/X tasks)
- [ ] Phase 6: Req Integration (0/X tasks)
- [ ] Phase 7: Testing (0/X tasks)
- [ ] Phase 8: Documentation (0/X tasks)
- [ ] Phase 9: Examples (0/X tasks)
- [ ] Phase 10: Production Readiness (0/X tasks)
- [ ] Phase 11: Release (0/X tasks)
- [ ] Phase 12: Post-Release (0/X tasks)

**Overall Progress:** 0% complete

---

## Notes

- Prioritize Phases 1-7 for MVP (Minimum Viable Product)
- Phase 4 (Phoenix Handler) is critical for initial users
- Phase 6 (Req Integration) is a key differentiator
- Consider beta release after Phase 8
- Gather feedback before v1.0
