# Migrating from Superpowers to Supersuit

Supersuit is a **framework fork** of [obra/superpowers](https://github.com/obra/superpowers). It is **not a drop-in**. The plugin id is `supersuit`. Skill invocations are `supersuit:<skill>`. The bootstrap skill folder is still `using-superpowers` (invoked as `supersuit:using-superpowers`). The telemetry env var is still `SUPERPOWERS_DISABLE_TELEMETRY`.

Official marketplace listings named `superpowers` still install **upstream** Superpowers. Install this fork from this repository.

Do **not** enable Superpowers and Supersuit in the same harness profile. They share skill folder names, the same SessionStart bootstrap, and overlapping overlay/scratch paths, and they will fight.

This is a one-time migration. There is no install-identity shim.

## 1. Uninstall Superpowers

Remove the upstream plugin from each harness you use. Leave leftover project files in place until step 3 — the rewrite script and the compatibility fallback handle those.

## 2. Install Supersuit

Install from this repository. Official marketplace `superpowers` is upstream.

Claude Code:

```bash
/plugin marketplace add https://github.com/jeighty/supersuit
/plugin install supersuit@supersuit-dev
```

Other harnesses: see [Installation](../README.md#installation) in the README. Use the current commands there, not a marketplace search for `superpowers`.

After install, invoke the bootstrap as `supersuit:using-superpowers`.

## 3. Rewrite invocations and move leftover dirs

Run the script from a checkout or plugin install of this repository. The bash wrapper `scripts/migrate-to-supersuit` execs `scripts/lib/migrate_to_supersuit.py`; if you copy the helper out, copy both files and keep that relative layout. Do not run it with no path from this checkout — that dry-runs a rewrite of this repo’s own docs and tests.

```bash
# Dry-run (default): prints planned rewrites and moves, writes nothing
./scripts/migrate-to-supersuit -n /path/to/your/project

# Apply
./scripts/migrate-to-supersuit --write /path/to/your/project

# Also move ~/.superpowers/ → ~/.supersuit/ (opt-in)
./scripts/migrate-to-supersuit --write --user /path/to/your/project
```

Point the script at personal/user instruction files if they contain `superpowers:` invocations:

```bash
./scripts/migrate-to-supersuit --write \
  /path/to/your/project \
  ~/.claude/CLAUDE.md \
  ~/.codex/AGENTS.md
```

### What the script changes

- Replaces the skill-namespace prefix `superpowers:` → `supersuit:` in text files (so `superpowers:brainstorming` becomes `supersuit:brainstorming`, and `superpowers:using-superpowers` becomes `supersuit:using-superpowers`).
- Moves project `.superpowers/` → `.supersuit/` when `.supersuit/` does not already exist (overlays plus SDD/brainstorm scratch).
- With `--user`, does the same for `~/.superpowers/` → `~/.supersuit/`.

### What the script does not change

- `.superpowers/` or `~/.superpowers/` **path segments in text** (those dirs are moved on disk; leftover strings are left alone)
- the skill folder / skill name `using-superpowers`
- `SUPERPOWERS_` environment variable names
- `obra/superpowers` and other upstream-product references that are not invocation prefixes
- binary files
- an existing `.supersuit/` directory (it will not clobber; leftover `.superpowers/` stays)

A naive `superpowers` → `supersuit` replace is wrong. Only the `superpowers:` prefix is rewritten.

## 4. Config dirs

**Canonical:** `.supersuit/` and `~/.supersuit/`. New overlays and new SDD/brainstorm scratch are written there.

**Compatibility fallback (one release):** if the canonical file or scratch dir is absent, resolvers and writers still **read** project `.superpowers/` then `~/.superpowers/`. That is not the long-term name. After you run the script, prefer `.supersuit/workflow.yaml` and `~/.supersuit/workflow.yaml`.

If `.superpowers/` is in `.gitignore`, add `.supersuit/` too.

See [workflow-config.md](workflow-config.md).
