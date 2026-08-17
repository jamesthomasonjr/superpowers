# Workflow Deterministic Run/Exec Actions — Design Spec

**Status:** Design + implementation for this fork (issue #5).
**Product:** Supersuit (`jamesthomasonjr/superpowers`).
**Depends on:** Configurable workflow graph (merged via #4).
**Pairs with:** Capability-aware overlays (#6); enables non-agent workspace
management (#7).

## Problem

Some pipeline steps are mechanical (create a git worktree, ensure ignore rules,
lay out a workspace path). Today a workflow logical id can only resolve to a
**skill**, or a transition can target `null` / `wait`. Encoding mechanics as
LLM skills wastes tokens and invites nondeterministic results. External
harnesses or allowlisted scripts are a better fit for deterministic work.

## Goals

| Priority | Goal |
|----------|------|
| Primary | Extend the skills registry so a logical id may resolve to a deterministic `run` / `exec` action. |
| Secondary | Map process exit (and optional structured stdout later) to outcomes such as `complete` / `failed`. |
| Safety | Allowlist executable paths under plugin and/or project roots only. |
| Compatibility | Additive to schema **version 1**. Bundled `workflows/default.yaml` stays free of `run` actions so zero-config still matches Superpowers methodology. |

## Non-goals (this change)

- Shipping any default-graph `run` nodes (opt-in via overlays only).
- Full external orchestrator that locks the agent out of shell.
- Arbitrary remote URLs, package installs, or third-party runners.
- Structured stdout → outcome mapping beyond exit-code maps (deferred).

## Design decisions

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | Registry key `run:` (canonical); `exec:` accepted as alias and normalized to `run` in resolved JSON. | Matches issue language; one shape in the artifact agents read. |
| 2 | `run.argv` is a non-empty string list; first element is the program path. | Deterministic argv; no shell string interpolation. |
| 3 | Program path must resolve under allowlisted roots (`plugin`, `project`; default both). | Prevents overlays from pointing at `/usr/bin/…` or home-dir exfil scripts. |
| 4 | Relative program paths resolve against **project root** first, then **plugin root** if not found (when both allowed). | Project overlays can ship scripts; plugin can ship shared helpers. |
| 5 | Exit → outcome via `run.outcomes` map; keys `0` / integer strings and optional `nonzero`. Defaults: `0→complete`, `nonzero→failed`. | Enough for chaining; no JSON protocol required for v1. |
| 6 | `run` is mutually exclusive with `skill` and `path` on the same registry entry. | One resolution mode per logical id. |
| 7 | Helper CLI `scripts/run-workflow-action` executes a resolved run id and prints `{id, outcome, exit_code}`. | Harnesses and agents get a deterministic executor without inventing argv. |
| 8 | Schema stays `version: 1` (additive). | Overlay adoption is still early; no need for 1.1 yet. |

## Config shape

```yaml
version: 1

skills:
  ensure-worktree:
    run:
      argv:
        - scripts/ensure-worktree.sh
        - --project-root
        - .
      # optional; default [plugin, project]
      allow:
        - project
      outcomes:
        0: complete
        nonzero: failed

transitions:
  - from: brainstorming
    on: approved-architectural
    to: ensure-worktree
  - from: ensure-worktree
    on: complete
    to: writing-plans
  - from: ensure-worktree
    on: failed
    to: wait
```

### Field semantics

| Field | Meaning |
|-------|---------|
| `skills.<id>.run` | Deterministic action (not a skill body). |
| `skills.<id>.exec` | Alias for `run`; rejected if both `run` and `exec` are set. |
| `run.argv` | Non-empty list of strings. `argv[0]` is the program (path). |
| `run.allow` | Subset of `{plugin, project}` controlling where `argv[0]` may live. Default: both. |
| `run.outcomes` | Map of exit-code token → outcome string. Token `nonzero` matches any non-zero exit. Missing map uses defaults above. |
| `run.cwd` | Optional: `project` (default) or `plugin`. Working directory for the process. |

## Resolution and agent rules

1. Logical id lookup order becomes: **`run`/`exec` → `path` → `skill` alias → same-name skill**.
2. When `to` points at a run id, the agent/harness **must not** invent a skill invoke. It should run `scripts/run-workflow-action --id <id>` (or an equivalent harness exec hook that uses the same argv/allow rules), read the printed outcome, then follow the map for `(from=<id>, on=<outcome>)`.
3. SessionStart / `<WORKFLOW_MAP>` text documents run semantics alongside `null` / `wait`.

## Components

1. **Validator** — extend `validate_workflow` for run entries (mutual exclusion, argv, allow, path containment, outcomes).
2. **Executor CLI** — `scripts/run-workflow-action` loads the resolved map, verifies the id is a run entry, re-checks allowlist, runs `subprocess`, maps exit → outcome, prints JSON.
3. **Bootstrap copy** — `using-superpowers` Workflow map section + SessionStart header.
4. **Docs** — `docs/workflow-config.md` example; this design spec.

## Errors

| Case | Behavior |
|------|----------|
| `run` + `path` / `skill` | Validation error. |
| `run` + `exec` both set | Validation error. |
| `argv[0]` outside allow roots | Validation error (resolve) / executor refuses. |
| Unknown logical id to `run-workflow-action` | Non-zero exit; stderr message. |
| Id is a skill, not a run | Non-zero exit; do not execute. |
| Exit code with no outcome mapping and no `nonzero` | Treat as `failed`. |

## Testing

- YAML: nested mapping/sequence under list items (loader fix for future `when:` and richer transition metadata).
- Validate accept/reject matrix for run entries.
- Executor: fixture script under project; exit 0 → `complete`; exit 1 → `failed`.
- Reject executor path escape outside allow roots.
- Bundled default still has no `run` keys.

## Success criteria

- Overlays can insert a mechanical step between skills without writing an LLM skill.
- Default (no overlays) behavior unchanged.
- No new third-party dependencies.
- Executable paths cannot escape plugin/project allow roots.

## Alternatives considered

| Approach | Why not |
|----------|---------|
| Thin “defer to harness” skills | Agent still mediates; still nondeterministic. |
| `to: wait` + human/external tool only | Works today; no automatic chain. |
| Full external orchestrator | Overkill; harness-heavy. |
| Shell string instead of argv | Injection / quoting hazards. |
