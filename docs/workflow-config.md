# Workflow configuration

**Supersuit** routes pipeline handoffs through a **resolved workflow map** instead of hard-coded skill directives. Skills emit stable **outcomes**; the map selects the next step (`to`). With no overlays, the bundled map matches the Superpowers pipeline.

Config layers stay under `.superpowers/` so overlays remain familiar; the **plugin id** is `supersuit`.

**Design spec:** [docs/superpowers/specs/2026-08-16-configurable-workflow-graph-design.md](superpowers/specs/2026-08-16-configurable-workflow-graph-design.md)

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
| `<logical id>` | Invoke that skill next (resolve via the skills registry). |
| `null` | No pipeline handoff — continue the session. Description-triggered skills (TDD, debugging, etc.) still apply. |
| `wait` | Stop and ask your human partner what to do next. |

If a skill emits an outcome with no matching transition, treat it as `wait`.

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
- `to` must be `null`, `wait`, or a known logical skill id
- `path` must point at a directory containing `SKILL.md`
- a skill entry cannot set both `skill` and `path`

On SessionStart failure, the hook injects a warning and continues without the overlay map. Fix the YAML and start a new session, or run `resolve-workflow` manually to see errors on stderr.
