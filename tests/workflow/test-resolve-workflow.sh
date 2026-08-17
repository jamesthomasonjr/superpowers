#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FAILURES=0
TEST_ROOT="$(mktemp -d)"
TEST_HOME="$TEST_ROOT/home"
mkdir -p "$TEST_HOME"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

pass() { echo "  [PASS] $1"; }
fail() { echo "  [FAIL] $1"; FAILURES=$((FAILURES + 1)); }

echo "=== workflow YAML loader ==="
if LOADER_OUT="$(python3 - "$REPO_ROOT" <<'PY'
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
)"; then
  pass "load_yaml parses subset"
else
  fail "load_yaml parses subset"
  echo "$LOADER_OUT" | sed 's/^/    /'
fi

echo "=== merge skills replace-by-id ==="
if python3 - "$REPO_ROOT" <<'PY'
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
then
  pass "skills replace-by-id"
else
  fail "skills replace-by-id"
fi

echo "=== merge transitions replace-by-from ==="
if python3 - "$REPO_ROOT" <<'PY'
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
then
  pass "transitions replace-by-from"
else
  fail "transitions replace-by-from"
fi

echo "=== default.yaml encodes core handoffs ==="
if python3 - "$REPO_ROOT" <<'PY'
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
then
  pass "default handoffs"
else
  fail "default handoffs"
fi

echo "=== merge rejects transition missing from ==="
if python3 - "$REPO_ROOT" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / "scripts" / "lib"))
from workflow_resolve import WorkflowResolveError, merge_workflows

base = {"version": 1, "skills": {}, "entries": {}, "transitions": []}
overlay = {"transitions": [{"on": "approved-architectural", "to": "writing-plans"}]}
try:
    merge_workflows(base, overlay)
    raise SystemExit("expected WorkflowResolveError")
except WorkflowResolveError:
    pass
print("ok")
PY
then
  pass "merge rejects transition missing from"
else
  fail "merge rejects transition missing from"
fi

echo "=== CLI resolves bundled defaults ==="
if OUT="$(cd "$REPO_ROOT" && "$REPO_ROOT/scripts/resolve-workflow" --plugin-root "$REPO_ROOT" --project-root "$REPO_ROOT" --user-home "$TEST_HOME")" &&
  echo "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["version"]==1; assert any(t["from"]=="brainstorming" and t["on"]=="approved-architectural" and t["to"]=="writing-plans" for t in d["transitions"])'; then
  pass "CLI resolves bundled defaults"
else
  fail "CLI resolves bundled defaults"
fi

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
if OUT="$(cd "$PROJ" && "$REPO_ROOT/scripts/resolve-workflow" --plugin-root "$REPO_ROOT" --project-root "$PROJ" --user-home "$TEST_HOME")" &&
  echo "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); t=[x for x in d["transitions"] if x["from"]=="brainstorming" and x["on"]=="approved-architectural"][0]; assert t["to"]=="wait"'; then
  pass "CLI project overlay wait"
else
  fail "CLI project overlay wait"
fi

echo "=== CLI invalid config exits 1 ==="
mkdir -p "$PROJ/.superpowers"
echo 'version: "nope"' > "$PROJ/.superpowers/workflow.yaml"
if "$REPO_ROOT/scripts/resolve-workflow" --plugin-root "$REPO_ROOT" --project-root "$PROJ" --user-home "$TEST_HOME" >/dev/null 2>"$TEST_ROOT/err.txt"; then
  fail "invalid config should exit 1"
else
  pass "invalid config exits 1"
fi

echo "=== merge rejects null skills ==="
if python3 - "$REPO_ROOT" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / "scripts" / "lib"))
from workflow_resolve import WorkflowResolveError, merge_workflows

base = {"version": 1, "skills": {}, "entries": {}, "transitions": []}
try:
    merge_workflows(base, {"skills": None})
    raise SystemExit("expected WorkflowResolveError for null skills")
except WorkflowResolveError as exc:
    assert "skills must be a mapping" in str(exc)
try:
    merge_workflows(base, {"entries": ["not", "a", "map"]})
    raise SystemExit("expected WorkflowResolveError for list entries")
except WorkflowResolveError as exc:
    assert "entries must be a mapping" in str(exc)
print("ok")
PY
then
  pass "merge rejects null skills"
else
  fail "merge rejects null skills"
fi

echo "=== CLI rejects non-mapping overlay ==="
mkdir -p "$PROJ/.superpowers"
printf '%s\n' '- just-a-list' > "$PROJ/.superpowers/workflow.yaml"
if "$REPO_ROOT/scripts/resolve-workflow" --plugin-root "$REPO_ROOT" --project-root "$PROJ" --user-home "$TEST_HOME" >/dev/null 2>"$TEST_ROOT/err-nonmap.txt"; then
  fail "non-mapping overlay should exit 1"
else
  if grep -qi 'must be a mapping' "$TEST_ROOT/err-nonmap.txt"; then
    pass "CLI rejects non-mapping overlay"
  else
    fail "CLI rejects non-mapping overlay"
    sed 's/^/    /' "$TEST_ROOT/err-nonmap.txt"
  fi
fi

echo "=== CLI bundled-only ignores invalid overlay ==="
if OUT="$(cd "$PROJ" && "$REPO_ROOT/scripts/resolve-workflow" --plugin-root "$REPO_ROOT" --project-root "$PROJ" --user-home "$TEST_HOME" --bundled-only)" &&
  echo "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["version"]==1; assert any(t["from"]=="brainstorming" and t["on"]=="approved-architectural" and t["to"]=="writing-plans" for t in d["transitions"])'; then
  pass "CLI bundled-only resolves defaults despite invalid overlay"
else
  fail "CLI bundled-only resolves defaults despite invalid overlay"
fi

echo "=== validate rejects transition missing to ==="
if python3 - "$REPO_ROOT" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / "scripts" / "lib"))
from workflow_resolve import validate_workflow

errors = validate_workflow(
    {
        "version": 1,
        "skills": {"brainstorming": {}, "writing-plans": {}},
        "entries": {},
        "transitions": [
            {"from": "brainstorming", "on": "approved-architectural"},
        ],
    },
    project_root=Path("."),
    bundled_skills={"brainstorming", "writing-plans"},
)
assert any("missing to" in e for e in errors), errors
print("ok")
PY
then
  pass "validate rejects transition missing to"
else
  fail "validate rejects transition missing to"
fi

echo "=== resolve wraps overlay OSError ==="
if python3 - "$REPO_ROOT" "$TEST_ROOT" <<'PY'
import sys
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(sys.argv[1]) / "scripts" / "lib"))
from workflow_resolve import WorkflowResolveError, resolve_workflow

repo = Path(sys.argv[1])
home = Path(sys.argv[2]) / "oserror-home"
proj = Path(sys.argv[2]) / "oserror-proj"
home.mkdir(parents=True)
proj.mkdir(parents=True)
(user_dir := home / ".superpowers").mkdir()
user_path = user_dir / "workflow.yaml"
user_path.write_text("version: 1\n", encoding="utf-8")

real_read_text = Path.read_text

def flaky_read_text(self, *args, **kwargs):
    if self == user_path:
        raise PermissionError("simulated unreadable overlay")
    return real_read_text(self, *args, **kwargs)

with patch.object(Path, "read_text", flaky_read_text):
    try:
        resolve_workflow(plugin_root=repo, project_root=proj, user_home=home)
        raise SystemExit("expected WorkflowResolveError")
    except WorkflowResolveError as exc:
        assert "failed to read user workflow" in str(exc), exc
print("ok")
PY
then
  pass "resolve wraps overlay OSError"
else
  fail "resolve wraps overlay OSError"
fi

echo "=== CLI unreadable overlay exits cleanly ==="
mkdir -p "$PROJ/.superpowers"
echo 'version: 1' > "$PROJ/.superpowers/workflow.yaml"
chmod 000 "$PROJ/.superpowers/workflow.yaml"
set +e
"$REPO_ROOT/scripts/resolve-workflow" --plugin-root "$REPO_ROOT" --project-root "$PROJ" --user-home "$TEST_HOME" >/dev/null 2>"$TEST_ROOT/err-unreadable.txt"
cli_status=$?
set -e
chmod 644 "$PROJ/.superpowers/workflow.yaml" || true
if grep -qi 'Traceback' "$TEST_ROOT/err-unreadable.txt"; then
  fail "unreadable overlay should not traceback"
  sed 's/^/    /' "$TEST_ROOT/err-unreadable.txt"
elif [[ "$cli_status" -ne 0 ]] && grep -qi 'failed to read project workflow' "$TEST_ROOT/err-unreadable.txt"; then
  pass "CLI unreadable overlay exits cleanly"
elif [[ "$cli_status" -eq 0 ]]; then
  pass "CLI unreadable overlay exits cleanly (overlay readable under this environment)"
else
  fail "CLI unreadable overlay exits cleanly"
  sed 's/^/    /' "$TEST_ROOT/err-unreadable.txt"
fi

echo "=== YAML nested mapping under sequence item ==="
if python3 - "$REPO_ROOT" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / "scripts" / "lib"))
from workflow_yaml import load_yaml
doc = load_yaml("""
transitions:
  - from: brainstorming
    on: approved-architectural
    to: ensure-worktree
    when:
      capabilities:
        - exec-hook
""")
t = doc["transitions"][0]
assert t["when"]["capabilities"] == ["exec-hook"]
print("ok")
PY
then
  pass "YAML nested mapping under sequence item"
else
  fail "YAML nested mapping under sequence item"
fi

echo "=== validate accepts run entry ==="
mkdir -p "$PROJ/scripts"
cat > "$PROJ/scripts/ensure-fixture.sh" <<'EOF'
#!/usr/bin/env bash
exit "${FIXTURE_EXIT:-0}"
EOF
chmod +x "$PROJ/scripts/ensure-fixture.sh"
cat > "$PROJ/.superpowers/workflow.yaml" <<'EOF'
version: 1
skills:
  ensure-fixture:
    run:
      argv:
        - scripts/ensure-fixture.sh
      allow:
        - project
      outcomes:
        0: complete
        nonzero: failed
transitions:
  - from: brainstorming
    on: approved-architectural
    to: ensure-fixture
  - from: brainstorming
    on: approved-bounded
    to: null
  - from: brainstorming
    on: approved-spike
    to: null
  - from: ensure-fixture
    on: complete
    to: writing-plans
  - from: ensure-fixture
    on: failed
    to: wait
EOF
if OUT="$(cd "$PROJ" && "$REPO_ROOT/scripts/resolve-workflow" --plugin-root "$REPO_ROOT" --project-root "$PROJ" --user-home "$TEST_HOME")" &&
  echo "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); e=d["skills"]["ensure-fixture"]; assert "run" in e; assert e["run"]["argv"][0]=="scripts/ensure-fixture.sh"; assert e["run"]["outcomes"]["0"]=="complete"'; then
  pass "validate accepts run entry"
else
  fail "validate accepts run entry"
fi

echo "=== exec alias normalizes to run ==="
cat > "$PROJ/.superpowers/workflow.yaml" <<'EOF'
version: 1
skills:
  ensure-fixture:
    exec:
      argv:
        - scripts/ensure-fixture.sh
      allow:
        - project
EOF
if OUT="$(cd "$PROJ" && "$REPO_ROOT/scripts/resolve-workflow" --plugin-root "$REPO_ROOT" --project-root "$PROJ" --user-home "$TEST_HOME")" &&
  echo "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); e=d["skills"]["ensure-fixture"]; assert "run" in e and "exec" not in e'; then
  pass "exec alias normalizes to run"
else
  fail "exec alias normalizes to run"
fi

echo "=== reject run+path combination ==="
cat > "$PROJ/.superpowers/workflow.yaml" <<'EOF'
version: 1
skills:
  ensure-fixture:
    path: ./nope
    run:
      argv:
        - scripts/ensure-fixture.sh
EOF
if "$REPO_ROOT/scripts/resolve-workflow" --plugin-root "$REPO_ROOT" --project-root "$PROJ" --user-home "$TEST_HOME" >/dev/null 2>"$TEST_ROOT/err-run-path.txt"; then
  fail "reject run+path combination"
else
  if grep -qi 'cannot combine' "$TEST_ROOT/err-run-path.txt"; then
    pass "reject run+path combination"
  else
    fail "reject run+path combination"
    sed 's/^/    /' "$TEST_ROOT/err-run-path.txt"
  fi
fi

echo "=== reject escaped run program ==="
cat > "$PROJ/.superpowers/workflow.yaml" <<'EOF'
version: 1
skills:
  bad-run:
    run:
      argv:
        - /bin/true
      allow:
        - project
EOF
if "$REPO_ROOT/scripts/resolve-workflow" --plugin-root "$REPO_ROOT" --project-root "$PROJ" --user-home "$TEST_HOME" >/dev/null 2>"$TEST_ROOT/err-escape.txt"; then
  fail "reject escaped run program"
else
  if grep -qi 'not found under allow roots\|run program' "$TEST_ROOT/err-escape.txt"; then
    pass "reject escaped run program"
  else
    fail "reject escaped run program"
    sed 's/^/    /' "$TEST_ROOT/err-escape.txt"
  fi
fi

echo "=== default.yaml has no run actions ==="
if python3 - "$REPO_ROOT" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / "scripts" / "lib"))
from workflow_yaml import load_yaml
doc = load_yaml((Path(sys.argv[1]) / "workflows" / "default.yaml").read_text())
for skill_id, entry in (doc.get("skills") or {}).items():
    assert isinstance(entry, dict)
    assert "run" not in entry and "exec" not in entry, skill_id
print("ok")
PY
then
  pass "default.yaml has no run actions"
else
  fail "default.yaml has no run actions"
fi

echo "=== run-workflow-action complete/failed ==="
cat > "$PROJ/.superpowers/workflow.yaml" <<'EOF'
version: 1
skills:
  ensure-fixture:
    run:
      argv:
        - scripts/ensure-fixture.sh
      allow:
        - project
EOF
if OUT="$(cd "$PROJ" && FIXTURE_EXIT=0 "$REPO_ROOT/scripts/run-workflow-action" --id ensure-fixture --plugin-root "$REPO_ROOT" --project-root "$PROJ" --user-home "$TEST_HOME")" &&
  echo "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["outcome"]=="complete"; assert d["exit_code"]==0'; then
  pass "run-workflow-action complete"
else
  fail "run-workflow-action complete"
fi
set +e
OUT="$(cd "$PROJ" && FIXTURE_EXIT=1 "$REPO_ROOT/scripts/run-workflow-action" --id ensure-fixture --plugin-root "$REPO_ROOT" --project-root "$PROJ" --user-home "$TEST_HOME" 2>/dev/null)"
status=$?
set -e
if [[ "$status" -ne 0 ]] && echo "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["outcome"]=="failed"; assert d["exit_code"]==1'; then
  pass "run-workflow-action failed"
else
  fail "run-workflow-action failed"
  echo "$OUT" | sed 's/^/    /'
fi

echo "=== run-workflow-action rejects skill id ==="
if "$REPO_ROOT/scripts/run-workflow-action" --id brainstorming --plugin-root "$REPO_ROOT" --project-root "$PROJ" --user-home "$TEST_HOME" >/dev/null 2>"$TEST_ROOT/err-not-run.txt"; then
  fail "run-workflow-action rejects skill id"
else
  if grep -qi 'not a run' "$TEST_ROOT/err-not-run.txt"; then
    pass "run-workflow-action rejects skill id"
  else
    fail "run-workflow-action rejects skill id"
    sed 's/^/    /' "$TEST_ROOT/err-not-run.txt"
  fi
fi

echo "=== run-workflow-action keeps JSON clean with noisy child ==="
cat > "$PROJ/scripts/noisy-fixture.sh" <<'EOF'
#!/usr/bin/env bash
echo "progress: starting"
echo "warning: chatter" >&2
exit 0
EOF
chmod +x "$PROJ/scripts/noisy-fixture.sh"
cat > "$PROJ/.superpowers/workflow.yaml" <<'EOF'
version: 1
skills:
  noisy-fixture:
    run:
      argv:
        - scripts/noisy-fixture.sh
      allow:
        - project
EOF
set +e
OUT="$(cd "$PROJ" && "$REPO_ROOT/scripts/run-workflow-action" --id noisy-fixture --plugin-root "$REPO_ROOT" --project-root "$PROJ" --user-home "$TEST_HOME" 2>"$TEST_ROOT/noisy-stderr.txt")"
status=$?
set -e
if [[ "$status" -eq 0 ]] &&
  echo "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["outcome"]=="complete"; assert d["exit_code"]==0' &&
  grep -q 'progress: starting' "$TEST_ROOT/noisy-stderr.txt" &&
  grep -q 'warning: chatter' "$TEST_ROOT/noisy-stderr.txt"; then
  pass "run-workflow-action keeps JSON clean with noisy child"
else
  fail "run-workflow-action keeps JSON clean with noisy child"
  echo "$OUT" | sed 's/^/    stdout: /'
  sed 's/^/    stderr: /' "$TEST_ROOT/noisy-stderr.txt"
fi

echo "=== gated transitions append without replace-by-from ==="
if python3 - "$REPO_ROOT" <<'PY'
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
  ],
}
overlay = {
  "transitions": [
    {
      "from": "brainstorming",
      "on": "approved-architectural",
      "to": "ensure-fixture",
      "when": {"capabilities": ["exec-hook"]},
    }
  ]
}
merged = merge_workflows(base, overlay)
assert len([t for t in merged["transitions"] if t["from"] == "brainstorming"]) == 3
assert any(t.get("when") for t in merged["transitions"])
assert any(t["on"] == "approved-bounded" for t in merged["transitions"])
print("ok")
PY
then
  pass "gated transitions append without replace-by-from"
else
  fail "gated transitions append without replace-by-from"
fi

echo "=== capability filter selects gated edge ==="
mkdir -p "$PROJ/scripts" "$PROJ/.superpowers"
cat > "$PROJ/scripts/ensure-fixture.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$PROJ/scripts/ensure-fixture.sh"
cat > "$PROJ/.superpowers/workflow.yaml" <<'EOF'
version: 1
skills:
  ensure-fixture:
    run:
      argv:
        - scripts/ensure-fixture.sh
      allow:
        - project
    when:
      capabilities:
        - exec-hook
transitions:
  - from: brainstorming
    on: approved-architectural
    to: ensure-fixture
    when:
      capabilities:
        - exec-hook
EOF
if OUT="$(cd "$PROJ" && "$REPO_ROOT/scripts/resolve-workflow" --plugin-root "$REPO_ROOT" --project-root "$PROJ" --user-home "$TEST_HOME")" &&
  echo "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); t=[x for x in d["transitions"] if x["from"]=="brainstorming" and x["on"]=="approved-architectural"][0]; assert t["to"]=="writing-plans"; assert "ensure-fixture" not in d["skills"] or d["skills"].get("ensure-fixture")=={} or "run" not in d["skills"].get("ensure-fixture",{})'; then
  pass "without capability keeps baseline edge"
else
  fail "without capability keeps baseline edge"
fi
if OUT="$(cd "$PROJ" && "$REPO_ROOT/scripts/resolve-workflow" --plugin-root "$REPO_ROOT" --project-root "$PROJ" --user-home "$TEST_HOME" --capabilities exec-hook)" &&
  echo "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "exec-hook" in d["capabilities"]; t=[x for x in d["transitions"] if x["from"]=="brainstorming" and x["on"]=="approved-architectural"][0]; assert t["to"]=="ensure-fixture"; assert "when" not in t; assert "run" in d["skills"]["ensure-fixture"]'; then
  pass "with capability selects gated edge"
else
  fail "with capability selects gated edge"
fi

echo "=== SUPERPOWERS_CAPABILITIES env works ==="
if OUT="$(cd "$PROJ" && SUPERPOWERS_CAPABILITIES=exec-hook "$REPO_ROOT/scripts/resolve-workflow" --plugin-root "$REPO_ROOT" --project-root "$PROJ" --user-home "$TEST_HOME")" &&
  echo "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); t=[x for x in d["transitions"] if x["from"]=="brainstorming" and x["on"]=="approved-architectural"][0]; assert t["to"]=="ensure-fixture"'; then
  pass "SUPERPOWERS_CAPABILITIES env works"
else
  fail "SUPERPOWERS_CAPABILITIES env works"
fi

echo "=== detect-capabilities adds session-inject ==="
if OUT="$(cd "$PROJ" && CURSOR_PLUGIN_ROOT=/tmp "$REPO_ROOT/scripts/resolve-workflow" --plugin-root "$REPO_ROOT" --project-root "$PROJ" --user-home "$TEST_HOME" --detect-capabilities --bundled-only)" &&
  echo "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "session-inject" in d["capabilities"]'; then
  pass "detect-capabilities adds session-inject"
else
  fail "detect-capabilities adds session-inject"
fi

echo "=== ambiguous equally-specific transitions fail ==="
cat > "$PROJ/.superpowers/workflow.yaml" <<'EOF'
version: 1
transitions:
  - from: brainstorming
    on: approved-architectural
    to: wait
    when:
      capabilities:
        - exec-hook
  - from: brainstorming
    on: approved-architectural
    to: writing-plans
    when:
      capabilities:
        - native-worktree
EOF
if "$REPO_ROOT/scripts/resolve-workflow" --plugin-root "$REPO_ROOT" --project-root "$PROJ" --user-home "$TEST_HOME" --capabilities exec-hook,native-worktree >/dev/null 2>"$TEST_ROOT/err-ambig.txt"; then
  fail "ambiguous equally-specific transitions fail"
else
  if grep -qi 'ambiguous' "$TEST_ROOT/err-ambig.txt"; then
    pass "ambiguous equally-specific transitions fail"
  else
    fail "ambiguous equally-specific transitions fail"
    sed 's/^/    /' "$TEST_ROOT/err-ambig.txt"
  fi
fi

if [[ "$FAILURES" -gt 0 ]]; then
  echo "FAILED: $FAILURES"
  exit 1
fi
echo "All workflow tests passed"
exit 0
