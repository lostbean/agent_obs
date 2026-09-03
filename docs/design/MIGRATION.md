# Legacy design migration map

- Migration status: draft; the mechanical gate and independent migration and code-conformance reviews pass, while owner approval of the migration and foundation remains required.
- No OpenSpec directory, OpenSpec configuration, or historical OpenSpec artifact was found in the repository.

| Legacy source | Preserved destination |
| --- | --- |
| `DESIGN.md` introduction and two-layer architecture | `docs/design/design.typ` Foundation, System at a glance, Instrumentation core, and Handler pipeline |
| `DESIGN.md` public API and event schema | `docs/design/design.typ` Instrumentation core and `docs/design/CONTEXT.typ` |
| `DESIGN.md` Phoenix translation and handler lifecycle | `docs/design/design.typ` Handler pipeline; ADRs 0001, 0002, and 0004 |
| `DESIGN.md` ReqLLM rationale and workflow | `docs/design/design.typ` Framework adapters and ADR 0003 |
| `DESIGN.md` end-to-end flow | `docs/design/design.typ` End-to-end walkthrough |
| `DESIGN.md` production, testing, and dependency guidance | `DEVELOPMENT.md`, `README.md`, `docs/COVERAGE.md`, and repository configuration |
| `DESIGN.md` planned exception, exporter, Generic span-kind, and streaming contracts that differ from code | Pending ledger and local tracker issues 01, 03, 04, and 07 |
| `DESIGN.md` chat-output requirement that differs from the current LLM stop validator | Pending ledger and local tracker issue 08 |
| Backend-neutral goal versus the implemented direct-OpenTelemetry Jido tracer | Pending ledger and local tracker issue 09 |
| Implemented span-context restoration limits found during conformance review | Pending ledger and local tracker issue 10 |
| `TODO.md` completed implementation history | Git history, tests, and current implementation; not duplicated into the design snapshot |
| `TODO.md` unresolved configuration and behavior mismatches | Pending ledger and local tracker issues 01–04 |
| `TODO.md` future documentation, examples, security, performance, integration, backend, tooling, community, and release ideas | `issues/legacy-roadmap/PRD.md` and issues 05–06 |
| Legacy architectural decisions | `docs/adr/0001-*.md` through `docs/adr/0006-*.md` |

- The root legacy files were removed after these destinations existed, the design rendered successfully, and the independent migration review found the preserved knowledge sufficient.
- Their historical wording and external bibliography remain recoverable from Git history; the migrated layer retains the project-specific contracts, rationale, terminology, and unresolved questions.
