# Design coverage

| System part | Status | Design owner or reason |
| --- | --- | --- |
| `lib/agent_obs.ex`, `lib/agent_obs/events.ex` | captured | [Instrumentation core](design/design.typ#instrumentation-core) |
| `lib/agent_obs/application.ex`, `lib/agent_obs/supervisor.ex`, `lib/agent_obs/handler.ex`, `lib/agent_obs/handlers/` | captured | [Handler pipeline](design/design.typ#handler-pipeline) |
| `lib/agent_obs/req_llm.ex`, `lib/agent_obs/jido_tracer.ex` | captured | [Framework adapters](design/design.typ#framework-adapters) |
| `config/` | captured | [Handler pipeline](design/design.typ#handler-pipeline) |
| `test/` | standard | Conventional executable specifications of the captured public and integration behavior. |
| `mix.exs`, `mix.lock`, `.formatter.exs`, `.credo.exs` | standard | Conventional Elixir dependency and quality configuration. |
| `flake.nix`, `flake.lock`, `.envrc`, `.github/`, `lefthook.yml` | standard | Conventional reproducible development, local-hook, and CI wiring. |
| `README.md`, `home.md`, `guides/` | captured | Public contracts are represented by the Instrumentation core, Handler pipeline, and Framework adapters; the migration map retains their legacy source relationship. |
| `DEVELOPMENT.md`, `CHANGELOG.md` | standard | Conventional maintainer workflow and release history. |
| `demo/` | out-of-scope | Example consumer application, not part of the published library package. |
| `LICENSE`, `.gitignore`, `.mcp.json`, `.claude/`, `AGENTS.md`, `CLAUDE.md`, `issues/` | out-of-scope | Repository governance, license, local tooling, and work tracking rather than product design. |
| `_build/`, `deps/`, `doc/`, package archives, crash dumps | out-of-scope | Generated or downloaded artifacts. |
