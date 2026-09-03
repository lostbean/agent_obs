<!-- agent-skills:begin -->
<!-- framework-commit: ce4f638169b6e03fa4032cb4bea3692bdc671628 origin: git@github.com:lostbean/skills.git -->

(machine-owned; do not edit inside this fence — re-run setup to refresh)

## Agent skills

**Design layer** — the design document is `docs/design/design.typ` (the layer renders to one `docs/design/design-layer.pdf`); terms are defined in `docs/design/CONTEXT.typ`; decisions are recorded in `docs/adr/`.

**Tracker** — local Markdown issues live under `issues/<feature-slug>/issues/<NN>-<slug>.md`; read and update the referenced file directly. Labels: `needs-triage` → `needs-triage`; `needs-info` → `needs-info`; `ready-for-agent` → `ready-for-agent`; `ready-for-human` → `ready-for-human`; `in-progress` → `in-progress`; `done` → `done`; `wontfix` → `wontfix`; `bug` → `bug`; `enhancement` → `enhancement`.

**AI disclaimer** — every AI-authored tracker comment starts with: `[AI-authored]`.

**Design gate** — `nix run .#design-gate-check -- docs/design .` checks the design layer (exit 0 clean, 1 violation, 2 error). One call runs the whole composite: render freshness, token coverage, and cross-link integrity. The gate is not stored in this repo — it is a pinned Nix flake input, so there are no check scripts to keep in step. Rebuild the rendered document with `nix run .#design-gate-render -- docs/design docs/design/design-layer.pdf`. The layer renders to ONE document: the design source is a chapter of `docs/design/design-layer.pdf`. A bare `typst compile` is NOT the gate — it misses every document-level contract.

**Staleness** — if the system has moved many commits since the design documents last changed, reconcile design and code before relying on the layer.

<!-- agent-skills:end -->
