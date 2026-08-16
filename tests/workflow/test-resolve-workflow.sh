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

if [[ "$FAILURES" -gt 0 ]]; then
  echo "FAILED: $FAILURES"
  exit 1
fi
echo "All workflow tests passed"
exit 0
