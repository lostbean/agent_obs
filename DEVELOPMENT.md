# Development Guide

This guide covers development workflows, code quality tools, and CI/CD setup for AgentObs.

## Quick Start

```bash
# Install dependencies
mix deps.get

# Run pre-commit checks
mix precommit

# Run CI checks
mix ci
```

## Code Quality Tools

### Formatting

AgentObs uses Elixir's built-in formatter:

```bash
# Format all files
mix format

# Check if files are formatted (CI)
mix format --check-formatted
```

Configuration is in `.formatter.exs`.

### Credo

Static code analysis for code quality and consistency:

```bash
# Run Credo
mix credo

# Run in strict mode (recommended for CI)
mix credo --strict

# Explain a specific issue
mix credo explain lib/agent_obs.ex:104
```

Configuration is in `.credo.exs`. Current settings:
- Max line length: 120 characters
- Module documentation required
- Strict consistency checks enabled
- TODOs allowed (warning only)

### Type checking

Static type analysis is handled by Elixir's built-in set-theoretic
(gradual) type checker, which runs automatically during `mix compile`.
Treat its warnings as errors to gate on them:

```bash
# Type-check the project (forces a full recompile so all warnings surface)
mix compile --warnings-as-errors --force
```

PLT files are cached in `priv/plts/` and excluded from git.

## Mix Tasks

### `mix precommit`

Recommended to run before committing code:

1. **Formats code** - Auto-fixes formatting
2. **Runs tests** - Ensures all tests pass
3. **Runs Credo** - Checks code quality in strict mode

Exit status: Fails if tests fail or Credo finds issues.

### `mix ci`

Designed for continuous integration pipelines:

1. **Checks formatting** - Fails if code is not formatted
2. **Runs tests** - Ensures all tests pass
3. **Runs Credo** - Checks code quality in strict mode

Exit status: Fails if any check fails.

## Testing

```bash
# Run all tests
mix test

# Run with coverage
mix test --cover

# Run specific test file
mix test test/agent_obs_test.exs

# Run specific test
mix test test/agent_obs_test.exs:10

# Run tests matching a pattern
mix test --only agent
```

### Test Organization

```
test/
├── test_helper.exs           # Test configuration
├── agent_obs_test.exs        # Core API tests
└── agent_obs/
    ├── events_test.exs       # Event schema tests
    └── handlers/
        └── phoenix/
            └── translator_test.exs  # OpenInference translation tests
```

## GitHub Actions CI

The project includes a comprehensive CI workflow in `.github/workflows/ci.yml`:

### Test Matrix

The full behavioral suite runs on each supported compatibility pair:

| Elixir | OTP |
| --- | --- |
| 1.18.5 | 27.3.4.17 |
| 1.19.6 | 27.3.4.17 and 28.5.0.6 |
| 1.20.4 | 27.3.4.17, 28.5.0.6, and 29.0.6 |

Each matrix entry runs dependency installation, a forced compile with warnings
as errors, an explicit application-startup check, and the complete default
ExUnit suite. Compilation, startup, and behavioral compatibility are separate
steps. Integration tests that require provider credentials remain excluded by
the test configuration.

Dependencies and build artifacts use absolute, toolchain-specific paths. Cache
keys include the operating system, Elixir, OTP, Mix environment, and both lock
files, which prevents artifacts from crossing runtime boundaries.

Formatting and Credo run once on the canonical Elixir 1.20.4 / OTP 29.0.6
toolchain. A new Elixir or OTP line is added only after the project compiles and
the full default suite passes for every newly claimed valid pair; unsupported
language/runtime combinations are never added only to increase matrix size.

### CI Jobs

1. **Test matrix**
   - Compiles and runs the full default suite on each supported pair
   - Uses toolchain-isolated dependency and build caches

2. **Canonical quality job**
   - Checks formatting once
   - Runs Credo in strict mode once

3. **Design and workflow job**
   - Runs the pinned design-layer gate through the repository flake
   - Lints the GitHub Actions workflow

4. **Type-check gate**
   - Part of the compile step (`mix compile --warnings-as-errors --force`)
   - Surfaces the built-in set-theoretic type checker's findings as errors

## Code Style Guidelines

### Naming Conventions

- **Modules**: PascalCase (`AgentObs.Handlers.Phoenix`)
- **Functions**: snake_case (`trace_agent/3`)
- **Variables**: snake_case (`start_metadata`)
- **Atoms**: snake_case (`:agent_obs`)

### Documentation

All public modules and functions must have:
- `@moduledoc` with description and examples
- `@doc` for each public function
- `@spec` type specifications

Example:
```elixir
@doc """
Instruments an agent loop.

## Examples

    AgentObs.trace_agent("my_agent", %{input: "task"}, fn ->
      {:ok, "result"}
    end)
"""
@spec trace_agent(String.t(), map(), function()) :: term()
def trace_agent(name, metadata, fun) do
  # ...
end
```

### Pattern Matching

Prefer pattern matching in function heads:
```elixir
# Good
def normalize_message(%{role: role} = message) when is_atom(role) do
  %{message | role: to_string(role)}
end

# Avoid
def normalize_message(message) do
  if is_atom(message.role) do
    %{message | role: to_string(message.role)}
  end
end
```

### Error Handling

Use tagged tuples for error handling:
```elixir
{:ok, result} | {:error, reason}
```

Use `with` for sequential validation:
```elixir
with :ok <- validate_field(data, :name),
     :ok <- validate_field(data, :input) do
  {:ok, data}
end
```

## Pre-commit Hooks (Optional)

Install the tracked hook configuration once, then Lefthook runs the pinned
design gate and `mix precommit` before each commit:

```bash
nix develop -c lefthook install
```

## Troubleshooting

### Tests Failing

```bash
# Clean build artifacts
mix clean

# Re-fetch dependencies
mix deps.clean --all
mix deps.get

# Run tests again
mix test
```

### Type-check Issues

```bash
# Force a full recompile so all type-checker warnings surface
mix compile --warnings-as-errors --force
```

### Formatting Conflicts

```bash
# Auto-fix formatting
mix format

# Verify
mix format --check-formatted
```

## Release Process

1. Update version in `mix.exs`
2. Update `CHANGELOG.md` with changes
3. Run `mix precommit` to ensure quality
4. Commit changes
5. Tag release: `git tag v0.1.0`
6. Push: `git push && git push --tags`
7. Publish to Hex: `mix hex.publish`

## Getting Help

- **Mix tasks**: `mix help`
- **Credo**: `mix credo --help`
- **Tests**: `mix help test`
