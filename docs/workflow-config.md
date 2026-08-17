# Workflow configuration

**Supersuit** routes pipeline handoffs through a **resolved workflow map** instead of hard-coded skill directives. Skills emit stable **outcomes**; the map selects the next step (`to`). With no overlays, the bundled map matches the Superpowers pipeline.

Config layers stay under `.superpowers/` so overlays remain familiar; the **plugin id** is `supersuit`.

**Design specs:**
- [Configurable workflow graph](superpowers/specs/2026-08-16-configurable-workflow-graph-design.md)
- [Deterministic run/exec actions](superpowers/specs/2026-08-17-workflow-run-actions-design.md)
- [Capability-aware overlays](superpowers/specs/2026-08-17-workflow-capability-overlays-design.md)

## Layer precedence

Configs merge in order (lowest → highest precedence):

1. **Bundled defaults** — `workflows/default.yaml` in the plugin
2. **User overlay** — `~/.superpowers/workflow.yaml`
3. **Project overlay** — `.superpowers/workflow.yaml` in the project root

Later layers override earlier ones:

- **`skills`:** replace-by-logical-id (whole entry). `skills.brainstorming: {}` clears a lower-layer alias or path back to identity.
- **`entries`:** per-key replace.
- **`transitions`:** replace-by-`from` — overlay transitions for a `from` id replace all bundled/user edges with that same `from`.

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

Mechanical steps (ensure a worktree, lay out paths, etc.) can be registry entries that run an allowlisted argv instead of an LLM skill. The bundled default graph does **not** include any `run` actions — add them only via overlays.

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

The command prints JSON including `outcome` and `exit_code`. Use `outcome` as the map's `on` for the next handoff.

## Capability-aware overlays

Hosts differ (SessionStart injection, native worktrees, subagents, exec hooks, Canvas). Overlays may gate transitions and skill registry entries with `when.capabilities` so enhanced edges apply only when the host advertises those tokens.

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

Notes:

- **Gated** overlay transitions (`when:` present) are **appended** and do not replace baseline edges for that `from`.
- **Ungated** overlay transitions still use replace-by-`from`.
- At resolve time, among matching `(from, on)` candidates, the most specific satisfied `when` wins.
- Resolved JSON includes a `capabilities` list and has `when` stripped — agents follow the filtered map as-is.
- Pass capabilities explicitly or via env:

```bash
./scripts/resolve-workflow --plugin-root "$PWD" --project-root "$PWD" --user-home "$HOME" \
  --capabilities session-inject,exec-hook --pretty

SUPERPOWERS_CAPABILITIES=exec-hook ./scripts/resolve-workflow ...
```

SessionStart passes `--detect-capabilities` (currently auto-detects `session-inject` when hook env is present) and honors `SUPERPOWERS_CAPABILITIES`.

Known tokens: `session-inject`, `native-worktree`, `subagents`, `exec-hook`, `native-canvas`.

## Example: replace brainstorming with a custom skill path

Project file `.superpowers/workflow.yaml`:

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

If `~/.superpowers/workflow.yaml` remaps brainstorming but this project should use the bundled skill:

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

On SessionStart overlay failure, the hook warns and injects the bundled map. If even bundled resolve fails, it warns that no `WORKFLOW_MAP` is available (and does not claim defaults are in effect). Fix the YAML and start a new session, or run `resolve-workflow` manually to see errors on stderr.
