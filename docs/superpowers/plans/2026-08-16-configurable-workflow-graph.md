# Configurable Workflow Graph Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a data-driven workflow map (bundled defaults + user/project overlays) that owns skill handoffs, with SessionStart injection and pipeline skills converted to Outcomes — without changing the default Superpowers happy path.

**Architecture:** A zero-dependency Python resolver merges `workflows/default.yaml` ← `~/.superpowers/workflow.yaml` ← `.superpowers/workflow.yaml`, validates, and prints JSON. SessionStart appends the resolved map beside `using-superpowers`. Pipeline skills stop naming the next skill and emit stable outcomes instead; the map chooses `to` (`<id>` | `null` | `wait`).

**Tech Stack:** Python 3 stdlib only (no PyYAML dependency — ship a minimal YAML subset loader for our schema); Bash hooks/tests matching existing `tests/hooks/` style; Markdown skills.

**Spec:** `docs/superpowers/specs/2026-08-16-configurable-workflow-graph-design.md`

## Global Constraints

- **Zero third-party runtime dependencies** — do not add PyYAML, npm packages, or other deps. Python stdlib + existing bash/node test helpers only.
- **Default behavior preserved** — with no overlays, resolved transitions match today’s pipeline (brainstorming → writing-plans → SDD|executing-plans → finishing).
- **Terminal semantics:** `to: null` = continue session (no pipeline handoff); `to: wait` = stop and ask the human.
- **Skills merge:** replace-by-logical-id (whole entry). **Transitions merge:** replace-by-`from`.
- **Worktree open point (ruling):** keep `using-git-worktrees` as an **internal prerequisite** inside executing-plans / SDD procedure text for v1 — do **not** add graph edges for it. Remapping still works via the `skills:` registry.
- **Pipeline handoffs only:** strip continuation directives on brainstorming, writing-plans, executing-plans, subagent-driven-development. Leave true sub-procedures (e.g. writing-skills → TDD) alone.
- **Base branch:** all commits on a feature branch off `cursor/modular-functionality-aa6a`; PRs target that branch, not `main`.
- **Commit often** after each green task.

## File Structure

| Path | Responsibility |
|------|----------------|
| `workflows/default.yaml` | Bundled default graph + identity skill stubs for remappable skills |
| `scripts/lib/workflow_yaml.py` | Minimal YAML subset load/dump for our schema |
| `scripts/lib/workflow_resolve.py` | Merge, validate, resolve paths, emit resolved dict |
| `scripts/resolve-workflow` | CLI entrypoint (executable) |
| `hooks/session-start` | Run resolver; inject map or fallback warning |
| `skills/using-superpowers/SKILL.md` | Workflow map rules for harnesses with/without hooks |
| `skills/brainstorming/SKILL.md` | Outcomes; remove writing-plans directive |
| `skills/writing-plans/SKILL.md` | Outcomes; remove SDD/executing-plans directives |
| `skills/executing-plans/SKILL.md` | Outcomes; remove finishing directive (keep worktree prerequisite) |
| `skills/subagent-driven-development/SKILL.md` | Outcomes; remove finishing directive (keep worktree prerequisite) |
| `tests/workflow/test-resolve-workflow.sh` | Resolver unit/integration tests |
| `tests/hooks/test-session-start.sh` | Extend for map injection / invalid-config fallback |
| `tests/workflow/test-skill-handoff-lint.sh` | Forbid pipeline handoff phrases in converted skills |
| `docs/workflow-config.md` | User/project override examples |

---

### Task 1: Minimal YAML loader + failing resolver harness

**Files:**
- Create: `scripts/lib/workflow_yaml.py`
- Create: `scripts/lib/__init__.py` (empty)
- Create: `tests/workflow/test-resolve-workflow.sh`
- Create: `workflows/default.yaml` (minimal stub — full graph in Task 2)

**Interfaces:**
- Produces: `load_yaml(text: str) -> object`, `dump_yaml(obj) -> str` (dump optional; load required)
- Consumes: nothing

- [ ] **Step 1: Write the failing test script (loader + missing resolve CLI)**

Create `tests/workflow/test-resolve-workflow.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FAILURES=0

pass() { echo "  [PASS] $1"; }
fail() { echo "  [FAIL] $1"; FAILURES=$((FAILURES + 1)); }

echo "=== workflow YAML loader ==="
LOADER_OUT="$(python3 - "$REPO_ROOT" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / "scripts" / "lib"))
from workflow_yaml import load_yaml
text = """
version: 1
skills:
  brainstorming: {}
  writing-plans:
    skill: my-writing-plans
transitions:
  - from: brainstorming
    on: approved-bounded
    to: null
  - from: brainstorming
    on: approved-architectural
    to: writing-plans
entries:
  creative-work: brainstorming
"""
doc = load_yaml(text)
assert doc["version"] == 1
assert doc["skills"]["brainstorming"] == {}
assert doc["skills"]["writing-plans"]["skill"] == "my-writing-plans"
assert doc["transitions"][0]["to"] is None
assert doc["entries"]["creative-work"] == "brainstorming"
print("ok")
PY
)" || true

if [[ "$LOADER_OUT" == *"ok"* ]]; then
  pass "load_yaml parses subset"
else
  fail "load_yaml parses subset"
  echo "$LOADER_OUT" | sed 's/^/    /'
fi

echo "=== resolve-workflow CLI exists ==="
if [[ -x "$REPO_ROOT/scripts/resolve-workflow" ]]; then
  pass "resolve-workflow executable present"
else
  fail "resolve-workflow executable present"
fi

if [[ "$FAILURES" -gt 0 ]]; then
  echo "FAILED: $FAILURES"
  exit 1
fi
echo "All workflow tests passed"
exit 0
```

- [ ] **Step 2: Run test — expect failure**

Run: `bash tests/workflow/test-resolve-workflow.sh`

Expected: FAIL (no `workflow_yaml` module / no CLI)

- [ ] **Step 3: Implement minimal YAML loader**

Create `scripts/lib/__init__.py` (empty).

Create `scripts/lib/workflow_yaml.py` that supports only: comments (`#`), mappings, sequences, plain scalars, quoted strings, `null`/`~`, `true`/`false`, integers. No anchors, no multiline blocks beyond single-line values. Implement `load_yaml(text)`.

Also create stub `workflows/default.yaml`:

```yaml
version: 1
skills: {}
entries: {}
transitions: []
```

And stub `scripts/resolve-workflow`:

```bash
#!/usr/bin/env bash
echo '{"error":"not implemented"}' >&2
exit 1
```

`chmod +x scripts/resolve-workflow`

- [ ] **Step 4: Re-run loader portion — tighten test temporarily if needed so loader passes while CLI still fails, OR implement enough that the script’s first assert passes**

Iterate until `load_yaml` assertions pass. Leave CLI check failing until Task 3 if the combined script exits 1 — acceptable; alternatively split CLI assert behind a `TEST_CLI=1` later. Prefer: make Step 4 pass loader only by temporarily commenting CLI check, then restore in Task 3.

Recommended: change CLI check to soft until Task 3 — for this task, remove the CLI assert from the script and only test `load_yaml`. Add CLI asserts in Task 3.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/__init__.py scripts/lib/workflow_yaml.py workflows/default.yaml tests/workflow/test-resolve-workflow.sh
git commit -m "feat(workflow): add minimal YAML loader and test harness"
```

---

### Task 2: Bundled default graph + merge/validate library (TDD)

**Files:**
- Modify: `workflows/default.yaml` (full default graph)
- Create: `scripts/lib/workflow_resolve.py`
- Modify: `tests/workflow/test-resolve-workflow.sh`

**Interfaces:**
- Produces:
  - `KNOWN_SKILLS: list[str]` — bundled skill directory names
  - `merge_workflows(base: dict, overlay: dict) -> dict`
  - `validate_workflow(doc: dict, *, project_root: Path, bundled_skills: set[str]) -> list[str]` (empty = ok; else error messages)
  - `resolve_workflow(*, plugin_root: Path, project_root: Path, user_home: Path) -> dict` returning `{"version", "skills", "entries", "transitions", "ok": true}` or raises `WorkflowResolveError`
- Consumes: `load_yaml` from `workflow_yaml`

- [ ] **Step 1: Extend tests for merge + default golden transitions**

Append to `tests/workflow/test-resolve-workflow.sh`:

```bash
echo "=== merge skills replace-by-id ==="
python3 - "$REPO_ROOT" <<'PY' || fail "skills replace-by-id"
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / "scripts" / "lib"))
from workflow_resolve import merge_workflows

base = {"version": 1, "skills": {"brainstorming": {"path": "/old"}}, "entries": {}, "transitions": []}
user = {"skills": {"brainstorming": {"skill": "alias-a"}}}
project = {"skills": {"brainstorming": {"path": "/proj"}}}
m1 = merge_workflows(base, user)
assert m1["skills"]["brainstorming"] == {"skill": "alias-a"}
m2 = merge_workflows(m1, project)
assert m2["skills"]["brainstorming"] == {"path": "/proj"}
m3 = merge_workflows(m2, {"skills": {"brainstorming": {}}})
assert m3["skills"]["brainstorming"] == {}
print("ok")
PY
[[ $? -eq 0 ]] && pass "skills replace-by-id" || true

echo "=== merge transitions replace-by-from ==="
python3 - "$REPO_ROOT" <<'PY' || fail "transitions replace-by-from"
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / "scripts" / "lib"))
from workflow_resolve import merge_workflows

base = {
  "version": 1,
  "skills": {},
  "entries": {},
  "transitions": [
    {"from": "brainstorming", "on": "approved-architectural", "to": "writing-plans"},
    {"from": "brainstorming", "on": "approved-bounded", "to": None},
    {"from": "writing-plans", "on": "inline", "to": "executing-plans"},
  ],
}
overlay = {
  "transitions": [
    {"from": "brainstorming", "on": "approved-architectural", "to": "wait"},
    {"from": "brainstorming", "on": "approved-bounded", "to": None},
    {"from": "brainstorming", "on": "approved-spike", "to": None},
  ]
}
m = merge_workflows(base, overlay)
bs = [t for t in m["transitions"] if t["from"] == "brainstorming"]
assert len(bs) == 3
assert any(t["on"] == "approved-architectural" and t["to"] == "wait" for t in bs)
assert any(t["from"] == "writing-plans" for t in m["transitions"])
print("ok")
PY
[[ $? -eq 0 ]] && pass "transitions replace-by-from" || true

echo "=== default.yaml encodes core handoffs ==="
python3 - "$REPO_ROOT" <<'PY' || fail "default handoffs"
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / "scripts" / "lib"))
from workflow_yaml import load_yaml
doc = load_yaml((Path(sys.argv[1]) / "workflows" / "default.yaml").read_text())
pairs = {(t["from"], t["on"], t["to"]) for t in doc["transitions"]}
assert ("brainstorming", "approved-architectural", "writing-plans") in pairs
assert ("brainstorming", "approved-bounded", None) in pairs
assert ("brainstorming", "approved-spike", None) in pairs
assert ("writing-plans", "subagent-driven", "subagent-driven-development") in pairs
assert ("writing-plans", "inline", "executing-plans") in pairs
assert ("subagent-driven-development", "complete", "finishing-a-development-branch") in pairs
assert ("executing-plans", "complete", "finishing-a-development-branch") in pairs
print("ok")
PY
[[ $? -eq 0 ]] && pass "default handoffs" || true
```

Fix pass/fail plumbing so failed python blocks call `fail` correctly (use `if python3 ...; then pass; else fail; fi`).

- [ ] **Step 2: Run tests — expect fail**

Run: `bash tests/workflow/test-resolve-workflow.sh`

Expected: FAIL (`workflow_resolve` missing / default incomplete)

- [ ] **Step 3: Write full `workflows/default.yaml`**

```yaml
version: 1

skills:
  brainstorming: {}
  writing-plans: {}
  subagent-driven-development: {}
  executing-plans: {}
  finishing-a-development-branch: {}
  using-git-worktrees: {}
  test-driven-development: {}
  systematic-debugging: {}
  requesting-code-review: {}
  receiving-code-review: {}
  verification-before-completion: {}
  dispatching-parallel-agents: {}
  writing-skills: {}
  using-superpowers: {}

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

- [ ] **Step 4: Implement `scripts/lib/workflow_resolve.py`**

Implement `merge_workflows`, `validate_workflow`, and `KNOWN_SKILLS` discovery from `plugin_root/skills/*/SKILL.md`. Validation rules from the spec:

- `version` must be `1`
- no duplicate `(from, on)`
- `to` not in `{None, "wait"}` must be a known logical id (bundled skill names ∪ keys in `skills`)
- each skill entry: not both `skill` and `path`; if `path`, expand `~`, resolve relative to `project_root`, require `SKILL.md`
- alias `skill` must be non-empty string

Do **not** wire the CLI yet (Task 3).

- [ ] **Step 5: Run tests — expect pass for merge + default**

Run: `bash tests/workflow/test-resolve-workflow.sh`

Expected: PASS for new asserts

- [ ] **Step 6: Commit**

```bash
git add workflows/default.yaml scripts/lib/workflow_resolve.py tests/workflow/test-resolve-workflow.sh
git commit -m "feat(workflow): default graph and merge/validate library"
```

---

### Task 3: `resolve-workflow` CLI

**Files:**
- Modify: `scripts/resolve-workflow`
- Modify: `tests/workflow/test-resolve-workflow.sh`

**Interfaces:**
- Produces: CLI
  - Env: `SUPERPOWERS_PLUGIN_ROOT` (required or auto-detect from script location), `HOME`, cwd = project root
  - Flags: `--plugin-root`, `--project-root`, `--user-home`, `--pretty`
  - Stdout: resolved JSON `{"version":1,"skills":{...},"entries":{...},"transitions":[...]}`
  - Exit 0 on success; exit 1 + stderr on validation/parse failure
  - Missing overlay files are OK

- [ ] **Step 1: Add CLI tests**

```bash
echo "=== CLI resolves bundled defaults ==="
OUT="$(cd "$REPO_ROOT" && "$REPO_ROOT/scripts/resolve-workflow" --plugin-root "$REPO_ROOT" --project-root "$REPO_ROOT" --user-home "$TEST_HOME")"
echo "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["version"]==1; assert any(t["from"]=="brainstorming" and t["on"]=="approved-architectural" and t["to"]=="writing-plans" for t in d["transitions"])'

echo "=== CLI project overlay wait ==="
PROJ="$TEST_ROOT/proj"
mkdir -p "$PROJ/.superpowers"
cat > "$PROJ/.superpowers/workflow.yaml" <<'EOF'
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
EOF
OUT="$(cd "$PROJ" && "$REPO_ROOT/scripts/resolve-workflow" --plugin-root "$REPO_ROOT" --project-root "$PROJ" --user-home "$TEST_HOME")"
echo "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); t=[x for x in d["transitions"] if x["from"]=="brainstorming" and x["on"]=="approved-architectural"][0]; assert t["to"]=="wait"'

echo "=== CLI invalid config exits 1 ==="
mkdir -p "$PROJ/.superpowers"
echo 'version: "nope"' > "$PROJ/.superpowers/workflow.yaml"
if "$REPO_ROOT/scripts/resolve-workflow" --plugin-root "$REPO_ROOT" --project-root "$PROJ" --user-home "$TEST_HOME" >/dev/null 2>"$TEST_ROOT/err.txt"; then
  fail "invalid config should exit 1"
else
  pass "invalid config exits 1"
fi
```

Create `TEST_HOME` / `TEST_ROOT` with `mktemp -d` at top of script (like hooks tests).

- [ ] **Step 2: Run — expect fail**

Run: `bash tests/workflow/test-resolve-workflow.sh`

Expected: FAIL (CLI stub)

- [ ] **Step 3: Implement CLI**

`scripts/resolve-workflow`:

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$SCRIPT_DIR/lib/workflow_resolve.py" "$@"
```

Add `main()` to `workflow_resolve.py` with argparse for the flags above; load bundled + user (`$user_home/.superpowers/workflow.yaml`) + project (`$project_root/.superpowers/workflow.yaml`); print JSON (`json.dumps`, `default=` handling for clarity — `to: null` as JSON `null`, `wait` as string `"wait"`).

- [ ] **Step 4: Run — expect pass**

Run: `bash tests/workflow/test-resolve-workflow.sh`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add scripts/resolve-workflow scripts/lib/workflow_resolve.py tests/workflow/test-resolve-workflow.sh
git commit -m "feat(workflow): resolve-workflow CLI"
```

---

### Task 4: SessionStart injection + hook tests

**Files:**
- Modify: `hooks/session-start`
- Modify: `tests/hooks/test-session-start.sh`

**Interfaces:**
- Consumes: `scripts/resolve-workflow`
- Produces: injected context includes a `<WORKFLOW_MAP>` block with resolved JSON + handoff rules; on resolver failure, includes `WORKFLOW_CONFIG_WARNING` and still includes `using-superpowers`

- [ ] **Step 1: Add failing hook assertions**

In `tests/hooks/test-session-start.sh`, add cases:

1. Normal Cursor-shaped run: context contains `WORKFLOW_MAP` and `approved-architectural`
2. With invalid project workflow (run hook with `PWD`/`cwd` under a temp project that has bad yaml — session-start must detect project root via `PWD`): context contains `WORKFLOW_CONFIG_WARNING` and still contains `using-superpowers` / `EXTREMELY_IMPORTANT`, exit 0

If session-start currently has no project-root concept, pass project root as cwd when invoking the hook in the test (`(cd "$PROJ" && env ... "$HOOK")`).

- [ ] **Step 2: Run hook tests — expect fail**

Run: `bash tests/hooks/test-session-start.sh`

Expected: FAIL on new asserts

- [ ] **Step 3: Update `hooks/session-start`**

After reading `using-superpowers`:

1. Set `PLUGIN_ROOT` as today
2. Run `"$PLUGIN_ROOT/scripts/resolve-workflow" --plugin-root "$PLUGIN_ROOT" --project-root "${PWD}" --user-home "${HOME}"` into a variable
3. On success, append to session context:

```text
<WORKFLOW_MAP>
Handoffs are authoritative. Skills are terminal — do not invent next skills.
After a skill completes, use (from, on) -> to from this map.
to: <id> invokes that logical id (resolve via skills registry: path, then skill alias, else same name).
to: null means no pipeline handoff; continue the session (description-triggered skills still apply).
to: wait means stop and ask the human.
Missing outcome in the map: treat as wait.

RESOLVED_JSON
...json...
</WORKFLOW_MAP>
```

4. On failure, append `WORKFLOW_CONFIG_WARNING: using bundled defaults failed validation or resolve; continuing without overlay map.` and still inject using-superpowers. **Always exit 0.**

Escape JSON for embedding with existing `escape_for_json`.

- [ ] **Step 4: Run hook tests — expect pass**

Run: `bash tests/hooks/test-session-start.sh`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add hooks/session-start tests/hooks/test-session-start.sh
git commit -m "feat(workflow): inject resolved workflow map from SessionStart"
```

---

### Task 5: `using-superpowers` Workflow map section

**Files:**
- Modify: `skills/using-superpowers/SKILL.md`

**Interfaces:**
- Produces: agent-facing rules that match the injected map (for harnesses without SessionStart)

- [ ] **Step 1: Add section after "The Rule" (before Skill Priority)**

Exact content to insert:

```markdown
## Workflow map

Superpowers handoffs are owned by a resolved workflow map (bundled defaults,
optional `~/.superpowers/workflow.yaml`, optional `.superpowers/workflow.yaml`).

When SessionStart did not inject a `<WORKFLOW_MAP>` block, run
`resolve-workflow` from the plugin (or read its JSON stdout) before the first
skill handoff and whenever overlays may have changed.

Rules:
1. Skills are terminal units — do not invent pipeline handoffs from memory.
2. When a skill finishes, emit its declared outcome, then select `to` from the
   map for `(from=<logical id>, on=<outcome>)`.
3. `to: <id>` — invoke that logical id. Resolve via the map's skills registry:
   `path` → `skill` alias → same name.
4. `to: null` — no pipeline handoff; continue the session. Description-triggered
   skills (TDD, debugging, verification, etc.) still apply.
5. `to: wait` — stop and ask your human partner what to do next.
6. If the outcome is missing from the map, treat it as `wait`.
7. User instructions still take precedence over skills and the workflow map.
```

- [ ] **Step 2: Sanity check — file contains both `WORKFLOW_MAP` guidance and existing Red Flags table**

Run: `rg -n "Workflow map|Red Flags|1% chance" skills/using-superpowers/SKILL.md`

Expected: all three match

- [ ] **Step 3: Commit**

```bash
git add skills/using-superpowers/SKILL.md
git commit -m "docs(using-superpowers): document workflow map handoff rules"
```

---

### Task 6: Brainstorming Outcomes (strip writing-plans handoff)

**Files:**
- Modify: `skills/brainstorming/SKILL.md`

**Interfaces:**
- Produces outcomes: `approved-architectural`, `approved-bounded`, `approved-spike`
- Must not direct “invoke writing-plans” as a hard next step

- [ ] **Step 1: Edit terminal states**

Replace checklist item 9 / “Invoke writing-plans” / “Implementation: Invoke the writing-plans skill…” with an **Outcomes** section:

```markdown
## Outcomes

When this skill finishes, emit exactly one outcome (workflow map selects next):

| Path | Outcome | Meaning |
|------|---------|---------|
| Architectural, human approved written spec | `approved-architectural` | Design accepted; map default goes to writing-plans |
| Bounded, human approved in-chat design | `approved-bounded` | Map default is `null` — continue session and implement |
| Spike, probe complete | `approved-spike` | Map default is `null` — report was the deliverable |

Do not invent a next pipeline skill. Follow the resolved workflow map.
```

Update the Process Flow diagram terminal for architectural path from `"Invoke writing-plans skill"` to `"Emit outcome: approved-architectural"`.

Update prose that says “the ONLY skill you invoke after brainstorming is writing-plans” to “emit `approved-architectural` and follow the workflow map (bundled default points at writing-plans)”.

Keep HARD-GATE, three paths, red flags, visual companion — do not reword persuasion language except where it names the next skill as a directive.

- [ ] **Step 2: Grep for forbidden handoff phrases**

Run: `rg -n "invoke writing-plans|Invoke writing-plans|writing-plans is the next" skills/brainstorming/SKILL.md || true`

Expected: no directive matches (mentions inside the Outcomes table “map default goes to writing-plans” are OK as descriptive, not “you must invoke”)

- [ ] **Step 3: Commit**

```bash
git add skills/brainstorming/SKILL.md
git commit -m "refactor(brainstorming): emit outcomes instead of invoking writing-plans"
```

---

### Task 7: writing-plans Outcomes

**Files:**
- Modify: `skills/writing-plans/SKILL.md`

- [ ] **Step 1: Replace Execution Handoff directives**

Keep offering the two choices to the human. Change the REQUIRED SUB-SKILL lines to outcomes:

```markdown
## Outcomes

After the plan is saved and the human picks an execution approach, emit one:

| Human choice | Outcome |
|--------------|---------|
| Subagent-Driven | `subagent-driven` |
| Inline Execution | `inline` |

Do not invoke the next skill by name. Follow the resolved workflow map
(bundled defaults: `subagent-driven` → subagent-driven-development,
`inline` → executing-plans).
```

Remove `**REQUIRED SUB-SKILL:** Use superpowers:subagent-driven-development` / `executing-plans` as pipeline directives. Soft mention in the offer text that the map will route those outcomes is fine.

Also update the plan footer tip that says `REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development...` for agentic workers — change to: “After plan save, emit workflow outcomes `subagent-driven` or `inline` per human choice; do not hard-code the next skill.”

- [ ] **Step 2: Grep**

Run: `rg -n "REQUIRED SUB-SKILL" skills/writing-plans/SKILL.md || true`

Expected: no matches

- [ ] **Step 3: Commit**

```bash
git add skills/writing-plans/SKILL.md
git commit -m "refactor(writing-plans): emit subagent-driven/inline outcomes"
```

---

### Task 8: executing-plans + SDD Outcomes

**Files:**
- Modify: `skills/executing-plans/SKILL.md`
- Modify: `skills/subagent-driven-development/SKILL.md`

- [ ] **Step 1: executing-plans**

Keep Step 1 worktree prerequisite text (`use superpowers:using-git-worktrees` as internal procedure — allowed).

Replace finishing REQUIRED SUB-SKILL / “complete development → finishing” directive with:

```markdown
## Outcomes

When all tasks are complete and verified, emit:

| Outcome | Meaning |
|---------|---------|
| `complete` | Implementation finished; map default routes to finishing-a-development-branch |

Do not invent the next skill. Follow the workflow map.
```

- [ ] **Step 2: subagent-driven-development**

Same for finishing handoffs (diagram nodes and “Use superpowers:finishing-a-development-branch” / “Done! Using finishing…”): replace with emit `complete` + follow map.

Keep worktree prerequisite and requesting-code-review / TDD as in-skill procedures.

- [ ] **Step 3: Grep both files**

Run:

```bash
rg -n "REQUIRED SUB-SKILL: Use superpowers:finishing|Using superpowers:finishing-a-development-branch" \
  skills/executing-plans/SKILL.md skills/subagent-driven-development/SKILL.md || true
```

Expected: no pipeline-directive matches (procedure mentions of worktrees OK)

- [ ] **Step 4: Commit**

```bash
git add skills/executing-plans/SKILL.md skills/subagent-driven-development/SKILL.md
git commit -m "refactor(execution): emit complete outcome instead of finishing handoff"
```

---

### Task 9: Skill handoff lint + override docs

**Files:**
- Create: `tests/workflow/test-skill-handoff-lint.sh`
- Create: `docs/workflow-config.md`

- [ ] **Step 1: Write lint test**

```bash
#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FAILURES=0
# Forbidden *directive* patterns in pipeline skills (allow Outcomes descriptive text via careful patterns)
for f in brainstorming writing-plans executing-plans subagent-driven-development; do
  if rg -n "REQUIRED SUB-SKILL: Use superpowers:(writing-plans|subagent-driven-development|executing-plans|finishing-a-development-branch)" \
      "$REPO_ROOT/skills/$f/SKILL.md"; then
    echo "FAIL: $f still has pipeline REQUIRED SUB-SKILL"
    FAILURES=$((FAILURES+1))
  fi
done
if rg -n "invoke writing-plans skill|Invoke writing-plans skill" "$REPO_ROOT/skills/brainstorming/SKILL.md"; then
  echo "FAIL: brainstorming still invokes writing-plans"
  FAILURES=$((FAILURES+1))
fi
exit "$FAILURES"
```

- [ ] **Step 2: Run lint — expect pass**

Run: `bash tests/workflow/test-skill-handoff-lint.sh`

Expected: exit 0

- [ ] **Step 3: Write `docs/workflow-config.md`**

Document:

- Layer precedence
- Example: replace brainstorming via `path`
- Example: kill architectural chain with `to: wait`
- Example: clear override with `skills.brainstorming: {}`
- Point to `scripts/resolve-workflow` and the spec

- [ ] **Step 4: Commit**

```bash
git add tests/workflow/test-skill-handoff-lint.sh docs/workflow-config.md
git commit -m "test(workflow): handoff lint and user override docs"
```

---

### Task 10: Final verification gate

**Files:** none (verification only)

- [ ] **Step 1: Run all related tests**

```bash
bash tests/workflow/test-resolve-workflow.sh
bash tests/workflow/test-skill-handoff-lint.sh
bash tests/hooks/test-session-start.sh
```

Expected: all PASS

- [ ] **Step 2: Manual resolve smoke**

```bash
./scripts/resolve-workflow --plugin-root "$PWD" --project-root "$PWD" --user-home /tmp | python3 -m json.tool | head
```

Expected: JSON with version 1 and brainstorming transitions

- [ ] **Step 3: Commit any leftover fixes; push branch; open PR targeting `cursor/modular-functionality-aa6a`**

If dirty, commit. Then:

```bash
git push -u origin HEAD
```

PR title: `feat: configurable workflow graph`
PR base: `cursor/modular-functionality-aa6a`

---

## Self-review (author)

**Spec coverage:**
| Spec item | Task |
|-----------|------|
| Bundled default graph | 2 |
| Resolver merge/validate | 2–3 |
| Alias + path replacement | 2–3 (validate path) |
| SessionStart inject + fallback | 4 |
| using-superpowers rules | 5 |
| Skill Outcomes / strip handoffs | 6–8 |
| Skill lint | 9 |
| Override docs | 9 |
| Worktree as internal prerequisite | Global Constraints + Task 8 |
| No third-party deps | Global Constraints + YAML subset (Task 1) |
| Agent evals | Deferred (spec “follow-up”) — out of this plan |

**Placeholder scan:** none intentional.

**Type consistency:** resolved JSON uses `to: null` / `"wait"` / string ids; merge functions named `merge_workflows` / `validate_workflow` / `resolve_workflow` consistently.
