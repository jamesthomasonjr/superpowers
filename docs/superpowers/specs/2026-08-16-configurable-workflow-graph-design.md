# Configurable Workflow Graph — Design Spec

**Status:** Implemented on this fork (brainstormed 2026-08-16).
**Product name:** **Supersuit** — fork of Superpowers with a configurable
workflow graph; filesystem contract remains `.superpowers/` and related
Superpowers paths/ids.
**Scope:** This fork (`jamesthomasonjr/superpowers`). Not proposed for upstream
`obra/superpowers` core without a separate upstream conversation — upstream
treats the opinionated chain as product, and fork-specific workflow
customization is explicitly out of their acceptance criteria.
**Objective:** Make the skill pipeline data-driven so the workflow graph can be
rewired, individual skills can be replaced (alias or path), and the default
behavior still matches today’s Superpowers chain.

## Problem

Superpowers’ strength is the way skills feed into each other
(brainstorming → writing-plans → SDD/executing-plans → finishing, etc.). That
coupling is encoded as prose inside skill bodies (`REQUIRED SUB-SKILL`,
“invoke writing-plans”, flowchart terminal nodes). Consequences:

1. **Hard to rewire.** Changing “what comes next” means editing multiple skill
   files and keeping them consistent.
2. **Hard to replace one skill.** A custom brainstorming or TDD skill cannot
   sit in the same graph without forking those handoff strings.
3. **Hard to stop the chain.** Running brainstorming alone still primes
   writing-plans on the architectural path because the skill *is* the
   orchestrator.

There is no runtime orchestrator today — SessionStart injects
`using-superpowers`, and the model follows markdown. Any solution must work
with that reality across harnesses that do and do not support hooks.

## Goals

| Priority | Goal |
|----------|------|
| Primary | Rewire the workflow graph via configuration (named edges + simple conditions). |
| Secondary | Replace individual skills by logical id (alias to another skill name, or filesystem path). |
| Compatibility | Bundled default graph reproduces today’s chain when no user/project config exists. |
| Portability | Harness-agnostic config + resolver; inject where SessionStart exists; fall back to “read resolved map at skill boundaries” elsewhere. |

## Non-goals (v1)

- Full DAG / joins / parallel fan-out / arbitrary predicates (eventual “C”).
- External session orchestrator that unlocks one skill per turn.
- GUI workflow editor.
- Soft dual-source-of-truth overlays (config + prose handoffs both authoritative).
- Shipping this as an upstream-core PR without maintainer buy-in.

## Design decisions

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | **Hard separation:** skills are terminal units; the workflow config owns handoffs. | Chosen explicitly over soft overlay. One source of truth for “what’s next.” |
| 2 | **Approach:** declarative workflow map + SessionStart (or fallback) injection of a *resolved* map. | Fits existing bootstrap model; no third-party deps; enables remaps. |
| 3 | **Config layers:** bundled < user (`~/.superpowers/workflow.yaml`) < project (`.superpowers/workflow.yaml`). | Project can specialize; user defaults travel across repos. |
| 4 | **Graph v1:** named edges with simple `on` outcomes; not a full state machine. | Enough to encode SDD vs inline and brainstorm path terminals; leaves room for DAG later. |
| 5 | **Skill replacement:** alias *and* path override per logical id. | Supports installed alternate skills and ad-hoc project/user skill dirs. |
| 6 | **Default when no overrides:** bundled graph = current chain as data. | Fans keep the product feel; customization is opt-in via overrides. |
| 7 | **Transition merge:** replace-by-`from` (not append). | Avoids conflicting duplicate `(from, on)` pairs when overriding one node. |
| 8 | **Skills merge:** replace-by-logical-id (whole entry), not deep-merge of nested keys. | Prevents a user `skill` alias and a project `path` from combining into an invalid both-set entry; lets `{}` clear a lower-layer override back to identity. |
| 9 | **Terminal semantics:** `to: null` = no pipeline handoff, continue the session; `to: wait` = stop and ask the human. | Preserves today’s bounded path (implement after approval) while still allowing overrides that kill the chain. |
| 10 | **Handoffs vs triggers:** the graph models *completion handoffs* only. Situation-triggered skills (TDD while coding, systematic-debugging on bugs, verification-before-completion) stay description-driven via bootstrap unless remapped in `skills:`. | Matches how those skills already work; avoids forcing every cross-cutting concern into a linear edge. |

## Architecture

```
Config layers (merge)
  bundled/workflows/default.yaml
    → ~/.superpowers/workflow.yaml
      → .superpowers/workflow.yaml
            │
            ▼ resolve + validate
  Resolved workflow artifact
    - skills registry: logical_id → { skill name | path | identity }
    - transitions: (from, on) → to | null | wait
    - entries: intent → start logical_id (optional remaps)
            │
     ┌──────┴──────┐
     ▼             ▼
 SessionStart   Fallback: agent runs/reads
 injection      resolver at boundaries
     └──────┬──────┘
            ▼
 Agent executes skill (resolved location),
 emits declared outcome, follows map for next
```

**Invariants**

1. Skill bodies do not name the next skill as a directive.
2. Skills may declare **outcomes** they can emit (stable strings).
3. After a skill finishes, the agent selects `to` from the resolved map for
   `(from=current logical id, on=outcome)`:
   - `to: <logical id>` → invoke that skill next (via registry).
   - `to: null` → no pipeline handoff; continue the session. Description-
     triggered skills (TDD, etc.) still apply. This is the bounded-path
     default after brainstorming approval.
   - `to: wait` → stop; do not invent a next skill or start implementation;
     ask the human what to do.
4. Invoking a logical id uses the skills registry (path → alias → same-name).

## Config shape

```yaml
version: 1

skills:
  brainstorming: {}                    # identity: plugin skill of same name
  writing-plans:
    skill: my-writing-plans            # alias
  test-driven-development:
    path: ~/.superpowers/skills/my-tdd # or project-relative path

entries:
  creative-work: brainstorming
  bugfix: systematic-debugging

transitions:
  - from: brainstorming
    on: approved-architectural
    to: writing-plans
  - from: brainstorming
    on: approved-bounded
    to: null
  - from: brainstorming
    on: approved-spike
    to: null
  - from: writing-plans
    on: subagent-driven
    to: subagent-driven-development
  - from: writing-plans
    on: inline
    to: executing-plans
  - from: subagent-driven-development
    on: complete
    to: finishing-a-development-branch
  - from: executing-plans
    on: complete
    to: finishing-a-development-branch
```

### Field semantics

| Field | Meaning |
|-------|---------|
| `version` | Schema version; v1 resolver rejects unknown major versions. |
| `skills.<id>` | Registry entry. Empty object `{}` → identity (invoke skill named `<id>`), and when used in an overlay **clears** any lower-layer alias/path for that id. |
| `skills.<id>.skill` | Alias: invoke this installed skill name instead. |
| `skills.<id>.path` | Filesystem override: read `SKILL.md` from this directory (absolute, `~` expanded, or relative to project root). Mutually exclusive with `.skill` in the same entry; if both set, validation fails. |
| `entries` | Optional remaps for bootstrap “when this kind of work starts, prefer this logical id.” Does not replace description-based discovery; it disambiguates when multiple skills could apply. Per-key replace on overlay (flat string map). |
| `transitions[].from` | Logical id of the skill that just finished. |
| `transitions[].on` | Outcome string declared by that skill. |
| `transitions[].to` | Next logical id, `null` (continue session, no pipeline handoff), or `wait` (stop for the human). |

### Merge algorithm

1. Load bundled defaults.
2. If user file exists, apply overlays:
   - **`skills`:** replace-by-logical-id. If the overlay defines `skills.<id>`,
     that entire entry replaces the lower-layer entry for `<id>` (no nested
     deep-merge of `skill`/`path`). Overlay `skills.<id>: {}` resets to
     identity.
   - **`entries`:** per-key replace (overlay key wins).
   - **`transitions`:** replace-by-`from` — **drop** any earlier edges whose
     `from` appears in the overlay’s transitions, then append the overlay’s
     transitions for those `from` values (and any new `from`s).
3. Repeat with project file (highest precedence).
4. Validate the merged document.
5. Emit resolved JSON (and optional short markdown summary for injection).

Partial override files are encouraged — only list remapped skill ids and
changed `from` nodes.

**Example (project clears a user path override and kills the architectural handoff):**

```yaml
skills:
  brainstorming: {}   # back to bundled identity skill

transitions:
  - from: brainstorming
    on: approved-architectural
    to: wait
  - from: brainstorming
    on: approved-bounded
    to: null
  - from: brainstorming
    on: approved-spike
    to: null
```

## Components

### 1. Bundled default workflow

Path (proposed): `workflows/default.yaml`.

Must encode the current completion handoffs present in skill prose today,
including at minimum:

| from | on | to |
|------|----|----|
| brainstorming | approved-architectural | writing-plans |
| brainstorming | approved-bounded | null (continue session; implement via description-triggered skills such as TDD — same as today) |
| brainstorming | approved-spike | null (continue session after reporting; no pipeline handoff) |
| writing-plans | subagent-driven | subagent-driven-development |
| writing-plans | inline | executing-plans |
| subagent-driven-development | complete | finishing-a-development-branch |
| executing-plans | complete | finishing-a-development-branch |

**Worktree note:** `using-git-worktrees` is required at the start of
execution skills today, not as a post-brainstorming handoff in the skill
bodies. Default graph should model that as an outcome/edge from
execution entry (e.g. SDD/executing-plans `on: need-workspace` →
`using-git-worktrees`, then back), *or* keep it as an internal prerequisite
step declared inside those skills without naming a *different* next process
skill. Prefer modeling it as a declared prerequisite outcome in the default
graph so it remains rewireable. Exact edge names to be fixed in the
implementation plan against the current SDD/executing-plans text.

**Cross-cutting skills** (TDD, requesting-code-review,
verification-before-completion, systematic-debugging,
dispatching-parallel-agents, receiving-code-review, writing-skills) remain
trigger/description driven; they appear in `skills:` only so they can be
remapped/replaced.

### 2. Resolver

Zero third-party dependencies (bash and/or Python stdlib — match existing
hook style). Responsibilities:

- Locate and merge config layers.
- Expand `~`, resolve relative paths against project root (cwd / git root
  heuristic consistent with hooks).
- Validate:
  - YAML/JSON parse success
  - `version` supported
  - no duplicate `(from, on)`
  - every `to` that is not `null` or `wait` exists as a logical id in the
    merged skill set (identity entries implied for known bundled skills even
    if not listed)
  - `path` targets exist and contain `SKILL.md`
  - alias targets are non-empty strings
  - `.skill` and `.path` not both set
- Print machine-readable resolved JSON to stdout (hooks capture) and
  optionally write a cache file under `.superpowers/cache/` (project) or
  XDG/cache equivalent (user-only runs).
- Exit non-zero on hard validation failure when invoked explicitly; SessionStart
  wrapper catches this and falls back (see Errors).

### 3. Bootstrap / SessionStart

Extend `hooks/session-start` to:

1. Run the resolver.
2. On success, append the resolved map (compact JSON or structured summary)
   plus authoritative handoff rules to the injected context alongside
   `using-superpowers`.
3. On failure, inject `using-superpowers` unchanged plus a visible warning
   that workflow config was invalid and bundled defaults apply.

Update `using-superpowers` with a short **Workflow map** section:

- Skills are terminal; do not invent handoffs.
- After a skill completes, read the map; use `(from, on) → to`.
- `to: <id>` → invoke that logical id next (registry-resolved).
- `to: null` → no pipeline handoff; continue the session (description
  triggers still apply).
- `to: wait` → stop and ask the human; do not start the next pipeline step.
- Resolve skill location via the registry before invoke.
- Harnesses without injection: run the resolver (or read the cache) before
  the first skill use and again before each handoff if the map might have
  changed.

### 4. Skill body changes

For each skill that currently directs a next skill:

- Remove directive handoffs (`REQUIRED SUB-SKILL: Use superpowers:X` used as
  *pipeline* continuation, “invoke writing-plans”, flowchart nodes that name
  the next process skill as mandatory continuation).
- Add an **Outcomes** section listing stable outcome ids and when to emit
  them (preserve the same human-facing questions/choices).
- Keep intra-skill checklists, red flags, and eval-tuned language unless a
  handoff sentence must move — prefer moving handoff sentences to Outcomes
  + default graph rather than rewording persuasion content.

**Note on `writing-skills` guidance:** examples that teach authors to write
`REQUIRED SUB-SKILL` for *library composition inside a skill* (e.g. “use TDD
while writing skills”) are different from pipeline handoffs. Implementation
should distinguish:

- **Pipeline handoff** → remove; use outcomes + graph.
- **Background/process requirement while executing this skill** → may remain
  as “use skill X for Y” *within* the skill’s own procedure, or become an
  outcome if we want it rewireable. Default: leave true sub-procedures in
  place for v1; only strip *continuation* handoffs that advance the
  brainstorm→plan→execute→finish pipeline.

### 5. Replacement lookup order

When the agent (or a helper) resolves logical id `X`:

1. If registry has `path` → load that directory’s `SKILL.md`.
2. Else if registry has `skill` → invoke/install-name that skill.
3. Else → invoke/load `X`.

## Errors and edge cases

| Case | Behavior |
|------|----------|
| Missing user/project files | Skip; bundled only. |
| Invalid YAML / validation failure in SessionStart | Warn + fall back to bundled defaults; do not brick the plugin. |
| Explicit `resolve-workflow` CLI | Non-zero exit + stderr details. |
| Broken path / bad alias at invoke time | Report which logical id failed; do not invent a substitute. |
| Outcome missing from map | Same as `to: wait` — ask the human; do not invent a next skill. |
| Agent ignores map | Same class of failure as ignoring prose today; mitigate with bootstrap language + evals. |
| Upstream merge conflicts | Expected on skill files that lose prose handoffs; document as intentional fork divergence. |

## Testing

1. **Unit (resolver):** merge precedence; skills replace-by-id (user alias +
   project path does not combine; `{}` clears); transition replace-by-`from`;
   alias + path; `null` vs `wait`; validation failures; golden resolved JSON
   with empty overlays ≡ bundled default chain.
2. **Hook:** SessionStart output includes map (or fallback warning) under
   Claude-shaped and Cursor-shaped env vars (extend `tests/hooks/`).
3. **Skill lint (light):** process skills that used to hard-require a next
   pipeline skill no longer contain forbidden handoff phrases (allowlist
   exceptions for background sub-procedures if needed).
4. **Agent eval (follow-up):** remap brainstorming via `path`; confirm override
   is read; set architectural `to: wait`; confirm no auto writing-plans;
   confirm bounded `to: null` still proceeds to implementation.

## Rollout (implementation phases — not this doc’s job to plan in detail)

Suggested order for the later implementation plan:

1. Schema + bundled `default.yaml` + resolver + tests (behavior-preserving:
   map matches current chain; skills not yet stripped).
2. SessionStart + `using-superpowers` workflow section + harness fallback
   docs.
3. Strip pipeline handoffs / add Outcomes on brainstorming, writing-plans,
   executing-plans, subagent-driven-development (highest-churn path).
4. Document user/project override examples (replace one skill; kill one edge).
5. Optional evals.

## Success criteria

- With no overrides, agent behavior matches pre-change Superpowers pipeline
  (same handoff sequence for the happy path).
- A project config can set `brainstorming` / `approved-architectural` →
  `to: wait` and the agent stops after the spec without auto-invoking
  writing-plans; default `approved-bounded` → `to: null` still continues
  into normal in-session implementation.
- A user or project config can point `brainstorming.path` at an alternate
  skill directory and that content is what gets loaded for that logical id.
- Invalid project config does not prevent SessionStart bootstrap.
- No new third-party runtime dependencies.

## Open points for implementation plan (resolved enough for spec)

1. Exact default edges for `using-git-worktrees` relative to SDD/executing-plans
   — confirm against current skill text when encoding `default.yaml`.
2. Whether resolved artifact is JSON-only or also YAML — JSON for hooks is
   enough; YAML source remains the human format.
3. Cache invalidation — resolver should be cheap enough to run every
   SessionStart; cache is optional optimization.

## Alternatives considered

| Approach | Why not |
|----------|---------|
| Soft overlay (config overrides prose) | Two sources of truth; agents follow louder prose; remaps unreliable. |
| External orchestrator | Strongest enforcement but harness-heavy and overkill for v1. |
| Thinner default (no auto-handoffs unless configured) | Rejected; bundled default must preserve current product feel. |
