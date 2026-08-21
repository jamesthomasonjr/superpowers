# Workflow configuration

**Supersuit** routes pipeline handoffs through a **resolved workflow map** instead of hard-coded skill directives. Skills emit stable **outcomes**; the map selects the next step (`to`). With no overlays, the bundled map matches the Superpowers pipeline. That is the framework pitch: keep Superpowers methodology by default, then reshape the toolchain when you are ready — Supersuit is not a Superpowers replacement.

Config layers live under **`.supersuit/`** (canonical). Leftover `.superpowers/` still loads for one release when the canonical file is absent. The **plugin id** is `supersuit`.

**Design specs:**
- [Configurable workflow graph](superpowers/specs/2026-08-16-configurable-workflow-graph-design.md)
- [Deterministic run/exec actions](superpowers/specs/2026-08-17-workflow-run-actions-design.md)
- [Capability-aware overlays](superpowers/specs/2026-08-17-workflow-capability-overlays-design.md)
- [Harness/external workspace preference](superpowers/specs/2026-08-21-native-worktree-preference-design.md)
- [Visual-surface capability ladder](superpowers/specs/2026-08-21-visual-surface-ladder-design.md)

## Layer precedence

Configs merge in order (lowest → highest precedence):

1. **Bundled defaults** — `workflows/default.yaml` in the plugin
2. **Bundled capability overlays** — `workflows/overlays/*.yaml` (sorted by name). Always loaded, including with `--bundled-only`. Gated entries apply only when the matching capability is advertised.
3. **User overlay** — `~/.supersuit/workflow.yaml`, or `~/.superpowers/workflow.yaml` if the canonical file is absent
4. **Project overlay** — `.supersuit/workflow.yaml` in the project root, or `.superpowers/workflow.yaml` if the canonical file is absent

`.supersuit/` is the long-term name. `.superpowers/` is a compatibility fallback, not a second overlay layer: each of user and project picks **one** file (canonical wins). New writes go to `.supersuit/`. See [Migrating from Superpowers](migrating-from-superpowers.md).

Later layers override earlier ones:

- **`skills`:** ungated entries replace-by-logical-id (whole entry). `skills.brainstorming: {}` clears a lower-layer alias or path back to identity. Gated entries (`when:` present) accumulate as candidates and do not replace the ungated entry.
- **`entries`:** per-key replace.
- **`transitions`:** ungated overlay transitions still replace-by-`from`. Gated overlay transitions (`when:` present) are **appended** so a host-specific enhancement does not drop the baseline edges for that `from`.

Missing overlay files are fine. Run the resolver to inspect the merged result:

```bash
./scripts/resolve-workflow --plugin-root "$PWD" --project-root "$PWD" --user-home "$HOME"
```

Add `--pretty` for readable JSON.

## Terminal semantics

| `to` value | Meaning |
|------------|---------|
| `<logical id>` | Invoke that logical id next (resolve via the skills registry). |
| `null` | No pipeline handoff — continue the session. Description-triggered skills (TDD, debugging, etc.) still apply. |
| `wait` | Stop and ask your human partner what to do next. |

Every transition **must** include an explicit `to` key. Omitting `to` is a validation error (it is not treated as `null`). Write `to: null` when you want continue-session.

If a skill emits an outcome with no matching transition, treat it as `wait`.

## Skills registry lookup

For a logical id, resolve in order:

1. **`run` / `exec`** — deterministic action (see below)
2. **`path`** — load `SKILL.md` from that directory
3. **`skill`** — invoke that installed skill name
4. else — invoke/load the logical id as a same-name skill

A registry entry may set only one of `run`/`exec`, `path`, or `skill`.

## Deterministic run / exec actions

Mechanical steps (ensure a worktree, lay out paths, etc.) can be registry entries that run an allowlisted argv instead of an LLM skill. `workflows/default.yaml` itself has no `run` actions. A bundled capability overlay adds `ensure-worktree` only when `native-worktree` is advertised (see below). Other run actions still belong in user/project overlays.

```yaml
version: 1

skills:
  ensure-worktree:
    run:
      argv:
        - scripts/ensure-worktree.sh
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

Notes:

- `exec:` is accepted as an alias for `run:` and is normalized to `run` in resolved JSON.
- `argv[0]` must resolve to a file under the allowlisted roots (`plugin` and/or `project`; default both).
- Relative programs are tried under project root, then plugin root (when allowed).
- Execute with:

```bash
./scripts/run-workflow-action --id ensure-worktree --plugin-root "$PWD" --project-root "$PWD" --user-home "$HOME"
```

`run-workflow-action` **always** re-probes host capabilities (the same conservative detect SessionStart uses). You do not need `--detect-capabilities` on `--id`; `session-inject` cannot drop just because the documented invocation omitted that flag. Advertised tokens still come from `SUPERPOWERS_CAPABILITIES` and `--capabilities` — when the resolved map lists `capabilities`, forward them:

```bash
./scripts/run-workflow-action --id ensure-worktree --plugin-root "$PWD" --project-root "$PWD" --user-home "$HOME" \
  --capabilities session-inject,exec-hook
```

The command prints JSON including `outcome` and `exit_code` on **stdout**. Child script stdout/stderr are forwarded to the CLI's stderr so the JSON stays parseable. Use `outcome` as the map's `on` for the next handoff.

## Capability-aware overlays

Hosts differ (SessionStart injection, native worktrees, subagents, exec hooks, Canvas). One static graph either underserves capable hosts or assumes tools that are missing. Overlays may gate transitions and skill registry entries with `when.capabilities` so enhanced edges apply only when the host advertises those tokens.

```yaml
version: 1

skills:
  ensure-worktree:
    run:
      argv:
        - scripts/ensure-worktree.sh
      allow:
        - project
    when:
      capabilities:
        - exec-hook

transitions:
  - from: brainstorming
    on: approved-architectural
    to: ensure-worktree
    when:
      capabilities:
        - exec-hook
```

Write this as `.supersuit/workflow.yaml` (or leftover `.superpowers/workflow.yaml`). Without `exec-hook`, resolve keeps the bundled `approved-architectural → writing-plans` edge and omits the gated registry entry. With `exec-hook`, the gated edge and run entry win.

Notes:

- A `when.capabilities` list is **AND**: every listed token must be active. Express OR as two transitions.
- **Gated** overlay transitions (`when:` present) are **appended** and do not replace baseline edges for that `from`.
- **Ungated** overlay transitions still use replace-by-`from`.
- **Gated** overlay skill entries accumulate as candidates. They do not replace a lower-layer remap. If the gate misses, the ungated entry (user remap or bundled identity) remains.
- **Ungated** overlay skill entries still replace-by-logical-id.
- At resolve time, among matching `(from, on)` or skill-id candidates, the most specific satisfied `when` (largest capability set) wins. Equal-size ties are a validation/resolve error.
- Resolved JSON includes a `capabilities` list and has `when` stripped — agents follow the filtered map as-is. Do not re-read overlay `when:` clauses.
- Unknown capability tokens are allowed (forward-compatible) but do not match until advertised.
- `when` accepts only `capabilities`. Other keys (for example a product-name `harness:` switch) are rejected.

### How to declare `when`

```yaml
when:
  capabilities:
    - exec-hook
    - native-worktree
```

Place `when` on a transition and/or on a `skills.<id>` entry. The bundled `workflows/default.yaml` stays ungated.

### How capabilities are detected

Active capabilities are the union of, in order (first-seen wins for display order):

1. **Detect** — conservative process probes (see below). `resolve-workflow` probes only with `--detect-capabilities`. `run-workflow-action` always probes, so a documented `--id` invoke cannot drop SessionStart's `session-inject`.
2. **`SUPERPOWERS_CAPABILITIES`** — comma-separated tokens from the environment
3. **`--capabilities`** — comma-separated CLI tokens (forward the resolved map's `capabilities` list here)

```bash
./scripts/resolve-workflow --plugin-root "$PWD" --project-root "$PWD" --user-home "$HOME" \
  --capabilities session-inject,exec-hook --pretty

SUPERPOWERS_CAPABILITIES=exec-hook ./scripts/resolve-workflow --plugin-root "$PWD" \
  --project-root "$PWD" --user-home "$HOME"
```

SessionStart passes `--detect-capabilities` and honors `SUPERPOWERS_CAPABILITIES`.

| Token | Meaning | Auto-detected? |
|-------|---------|----------------|
| `session-inject` | Host injects bootstrap / workflow map at session start. | Yes, when `CURSOR_PLUGIN_ROOT`, `CLAUDE_PLUGIN_ROOT`, or `COPILOT_CLI` is set (SessionStart-like env). |
| `native-worktree` | Host owns worktree / workspace creation. | No. Advertise explicitly. Product name is not evidence. See [Advertising `native-worktree`](#advertising-native-worktree). |
| `subagents` | Host supports subagent dispatch. | No. Advertise explicitly. |
| `exec-hook` | Host can run deterministic workflow actions without the chat model mediating. | No. SessionStart running is not the same as an exec hook. |
| `native-canvas` | Host provides a native visual surface (e.g. Cursor Canvas). | No. Do not infer from `CURSOR_PLUGIN_ROOT`. See [Advertising `native-canvas`](#advertising-native-canvas). |

A missing capability probe (no hook env, no env override, no `--capabilities`) yields an empty set. Gated overlays do not apply. That is intentional: fail toward the Superpowers baseline rather than claiming Canvas, worktrees, subagents, or exec hooks from a product name.

## Advertising `native-worktree`

Hosts that already create the workspace (Cursor Cloud worktrees, an external
app, a harness-native `EnterWorktree` / equivalent) should **advertise**
`native-worktree`. Do not infer it from the product name.

```bash
export SUPERPOWERS_CAPABILITIES=native-worktree
```

Or pass it on the CLI (and forward the resolved map's `capabilities` list
into `run-workflow-action` so the token cannot drop):

```bash
./scripts/resolve-workflow --plugin-root "$PWD" --project-root "$PWD" \
  --user-home "$HOME" --capabilities native-worktree --pretty

./scripts/run-workflow-action --id ensure-worktree --plugin-root "$PWD" \
  --project-root "$PWD" --user-home "$HOME" --capabilities native-worktree
```

SessionStart already honors `SUPERPOWERS_CAPABILITIES` and always passes
`--detect-capabilities`. Detect still only adds `session-inject` from hook
env. `native-worktree` must be in the env or `--capabilities`.

When the token is advertised, the bundled overlay
`workflows/overlays/native-worktree.yaml` wins over the Superpowers baseline:

| Without `native-worktree` (and no user/project overlay) | With `native-worktree` advertised |
|--------------------------------------------------------|----------------------------------|
| `brainstorming / approved-architectural` → `writing-plans` | → `ensure-worktree` (run), then `writing-plans` on `complete` |
| `using-git-worktrees` is the Superpowers identity skill | remapped to the same `run` (`complete` → `null`) |
| Agent may still follow `supersuit:using-git-worktrees` | Do not load that skill or invent `git worktree` steps |

`scripts/ensure-worktree` is a handshake, not a creator. It never runs
`git worktree add`. Hosts that want a stricter check (must already be
isolated, or call a native tool) override the registry entry with the
**same** `when.capabilities: [native-worktree]` signature in
`.supersuit/workflow.yaml` — later layers upsert the same gate:

```yaml
version: 1

skills:
  ensure-worktree:
    run:
      argv:
        - scripts/my-ensure-worktree.sh
      allow:
        - project
    when:
      capabilities:
        - native-worktree
  using-git-worktrees:
    run:
      argv:
        - scripts/my-ensure-worktree.sh
      allow:
        - project
    when:
      capabilities:
        - native-worktree
```

## Advertising `native-canvas`

Hosts that provide a native visual surface (Cursor Canvas or equivalent)
should **advertise** `native-canvas`. Do not infer it from the product
name. The user-facing brainstorming offer stays product-agnostic
("visual surface"); operational chat may name the chosen surface once
after the user accepts.

```bash
export SUPERPOWERS_CAPABILITIES=native-canvas
```

Or pass it on the CLI (and forward the resolved map's `capabilities` list
into `run-workflow-action` so the token cannot drop):

```bash
./scripts/resolve-workflow --plugin-root "$PWD" --project-root "$PWD" \
  --user-home "$HOME" --capabilities native-canvas --pretty

./scripts/run-workflow-action --id visual-surface --plugin-root "$PWD" \
  --project-root "$PWD" --user-home "$HOME" --capabilities native-canvas
```

SessionStart already honors `SUPERPOWERS_CAPABILITIES` and always passes
`--detect-capabilities`. Detect still only adds `session-inject` from hook
env. `native-canvas` must be in the env or `--capabilities`.

When the token is advertised, the bundled overlay
`workflows/overlays/native-canvas.yaml` remaps `visual-surface` after the
user accepts the offer. This is **not** a pipeline handoff after
`approved-architectural` — selection happens mid-brainstorming.

| Without `native-canvas` (and no user/project overlay) | With `native-canvas` advertised |
|------------------------------------------------------|--------------------------------|
| `visual-surface` is the identity skill (companion-server portable default) | remapped to `scripts/select-visual-surface` (`run`) |
| Agent reads `supersuit:visual-surface` and starts the companion server on accept | Outcome `native` → native surface; `companion` → companion server; `text` → chat only |
| Declined offer is text-only | Same — decline never starts a surface |

`scripts/select-visual-surface` never invents `native-canvas` from Cursor,
Claude, Codex, or other product names. Hosts that want a different
selector override the registry entry with the **same**
`when.capabilities: [native-canvas]` signature in
`.supersuit/workflow.yaml`.

Policy (JIT offer, own-message, per-question visual vs text) stays in
`skills/brainstorming/SKILL.md`. Mechanics live in
`skills/visual-surface/`.

## Example: replace brainstorming with a custom skill path

Project file `.supersuit/workflow.yaml`:

```yaml
version: 1

skills:
  brainstorming:
    path: ./my-skills/custom-brainstorm
```

The directory must contain a `SKILL.md`. Paths may be absolute, use `~`, or be relative to the project root. A skill entry cannot set both `path` and `skill`.

## Example: stop the architectural chain (`to: wait`)

To run brainstorming without auto-routing to writing-plans on the architectural path:

```yaml
version: 1

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

Replace-by-`from` means you must list **all** outcomes for `brainstorming` you want to keep — omitted outcomes fall back to lower layers only for `from` ids not present in the overlay.

## Example: clear a user override back to bundled identity

If `~/.supersuit/workflow.yaml` remaps brainstorming but this project should use the bundled skill:

```yaml
version: 1

skills:
  brainstorming: {}
```

An empty object resets that logical id to identity (plugin skill of the same name).

## Validation

The resolver validates merged config before emitting JSON. Common failures:

- `version` must be `1`
- duplicate `(from, on)` pairs
- each transition must include `to` (`null`, `wait`, or a known logical skill id)
- `path` must point at a directory containing `SKILL.md`
- a skill entry cannot combine `skill`, `path`, and `run`/`exec`
- `run.argv[0]` must exist under the entry's `allow` roots
- `when` must be a mapping whose only key is `capabilities` (non-empty string list)
- equally-specific matching `(from, on)` gates for the active capability set are ambiguous

On SessionStart overlay failure, the hook warns and injects the bundled map. If even bundled resolve fails, it warns that no `WORKFLOW_MAP` is available (and does not claim defaults are in effect). Fix the YAML and start a new session, or run `resolve-workflow` manually to see errors on stderr.
