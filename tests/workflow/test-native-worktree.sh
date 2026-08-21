#!/usr/bin/env bash
# Issue #7: advertised native-worktree prefers ensure-worktree run;
# missing capability keeps Superpowers-shaped using-git-worktrees.
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

RESOLVE=("$REPO_ROOT/scripts/resolve-workflow" --plugin-root "$REPO_ROOT")
JSON_FILE="$TEST_ROOT/last.json"

write_json() {
  printf '%s' "$1" > "$JSON_FILE"
}

echo "=== ensure-worktree source never creates a git worktree ==="
if grep -E '^[[:space:]]*git[[:space:]]+worktree[[:space:]]+add' "$REPO_ROOT/scripts/ensure-worktree"; then
  fail "ensure-worktree source contains git worktree add"
else
  pass "ensure-worktree source has no git worktree add"
fi

echo "=== ensure-worktree handshake does not add a worktree ==="
WT_REPO="$TEST_ROOT/wt-repo"
mkdir -p "$WT_REPO"
git init -q "$WT_REPO"
git -C "$WT_REPO" config user.email "test@example.com"
git -C "$WT_REPO" config user.name "test"
echo hi > "$WT_REPO/file"
git -C "$WT_REPO" add file
git -C "$WT_REPO" commit -q -m init
BEFORE_LIST="$(git -C "$WT_REPO" worktree list)"
BEFORE_COUNT="$(git -C "$WT_REPO" worktree list | wc -l)"
WT_OUT="$(cd "$WT_REPO" && "$REPO_ROOT/scripts/ensure-worktree")"
AFTER_LIST="$(git -C "$WT_REPO" worktree list)"
AFTER_COUNT="$(git -C "$WT_REPO" worktree list | wc -l)"
if [[ "$BEFORE_LIST" == "$AFTER_LIST" ]] &&
  [[ "$BEFORE_COUNT" == "$AFTER_COUNT" ]] &&
  printf '%s' "$WT_OUT" | grep -q 'host-owned'; then
  pass "ensure-worktree does not add a worktree"
else
  fail "ensure-worktree does not add a worktree"
  echo "    before: $BEFORE_LIST"
  echo "    after:  $AFTER_LIST"
  echo "    out:    $WT_OUT"
fi

echo "=== missing capability keeps Superpowers worktree skill ==="
if OUT="$(cd "$REPO_ROOT" && env -u SUPERPOWERS_CAPABILITIES -u CURSOR_PLUGIN_ROOT -u CLAUDE_PLUGIN_ROOT -u COPILOT_CLI \
  "${RESOLVE[@]}" --project-root "$REPO_ROOT" --user-home "$TEST_HOME")"; then
  write_json "$OUT"
  if python3 - "$JSON_FILE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert "native-worktree" not in d.get("capabilities", [])
assert "run" not in d["skills"].get("using-git-worktrees", {})
assert "ensure-worktree" not in d["skills"]
t = [x for x in d["transitions"] if x["from"] == "brainstorming" and x["on"] == "approved-architectural"][0]
assert t["to"] == "writing-plans", t
PY
  then
    pass "missing capability keeps Superpowers worktree skill"
  else
    fail "missing capability keeps Superpowers worktree skill"
  fi
else
  fail "missing capability keeps Superpowers worktree skill"
fi

echo "=== missing-capability-probe does not invent native-worktree ==="
if OUT="$(cd "$REPO_ROOT" && env -u SUPERPOWERS_CAPABILITIES -u CURSOR_PLUGIN_ROOT -u CLAUDE_PLUGIN_ROOT -u COPILOT_CLI \
  "${RESOLVE[@]}" --project-root "$REPO_ROOT" --user-home "$TEST_HOME" --detect-capabilities --bundled-only)"; then
  write_json "$OUT"
  if python3 - "$JSON_FILE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("capabilities") == []
assert "ensure-worktree" not in d["skills"]
assert "run" not in d["skills"].get("using-git-worktrees", {})
t = [x for x in d["transitions"] if x["from"] == "brainstorming" and x["on"] == "approved-architectural"][0]
assert t["to"] == "writing-plans"
PY
  then
    pass "missing-capability-probe keeps Superpowers baseline"
  else
    fail "missing-capability-probe keeps Superpowers baseline"
  fi
else
  fail "missing-capability-probe keeps Superpowers baseline"
fi

echo "=== Cursor env alone does not invent native-worktree ==="
if OUT="$(cd "$REPO_ROOT" && env -u SUPERPOWERS_CAPABILITIES CURSOR_PLUGIN_ROOT=/tmp \
  "${RESOLVE[@]}" --project-root "$REPO_ROOT" --user-home "$TEST_HOME" --detect-capabilities --bundled-only)"; then
  write_json "$OUT"
  if python3 - "$JSON_FILE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("capabilities") == ["session-inject"]
assert "native-worktree" not in d.get("capabilities", [])
assert "ensure-worktree" not in d["skills"]
assert "run" not in d["skills"].get("using-git-worktrees", {})
t = [x for x in d["transitions"] if x["from"] == "brainstorming" and x["on"] == "approved-architectural"][0]
assert t["to"] == "writing-plans"
PY
  then
    pass "Cursor env alone does not invent native-worktree"
  else
    fail "Cursor env alone does not invent native-worktree"
  fi
else
  fail "Cursor env alone does not invent native-worktree"
fi

echo "=== advertised native-worktree selects ensure-worktree run ==="
if OUT="$(cd "$REPO_ROOT" && env -u SUPERPOWERS_CAPABILITIES \
  "${RESOLVE[@]}" --project-root "$REPO_ROOT" --user-home "$TEST_HOME" --capabilities native-worktree --bundled-only)"; then
  write_json "$OUT"
  if python3 - "$JSON_FILE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert "native-worktree" in d["capabilities"]
assert "when" not in d["skills"]["ensure-worktree"]
assert "run" in d["skills"]["ensure-worktree"]
assert d["skills"]["ensure-worktree"]["run"]["argv"][0].endswith("ensure-worktree")
assert "run" in d["skills"]["using-git-worktrees"]
assert d["skills"]["using-git-worktrees"]["run"]["argv"][0].endswith("ensure-worktree")
arch = [x for x in d["transitions"] if x["from"] == "brainstorming" and x["on"] == "approved-architectural"][0]
assert arch["to"] == "ensure-worktree", arch
assert "when" not in arch
done = [x for x in d["transitions"] if x["from"] == "ensure-worktree" and x["on"] == "complete"][0]
assert done["to"] == "writing-plans"
failed = [x for x in d["transitions"] if x["from"] == "ensure-worktree" and x["on"] == "failed"][0]
assert failed["to"] == "wait"
ugw = [x for x in d["transitions"] if x["from"] == "using-git-worktrees" and x["on"] == "complete"][0]
assert ugw["to"] is None
PY
  then
    pass "advertised native-worktree selects ensure-worktree run"
  else
    fail "advertised native-worktree selects ensure-worktree run"
  fi
else
  fail "advertised native-worktree selects ensure-worktree run"
fi

echo "=== SUPERPOWERS_CAPABILITIES=native-worktree selects gated overlay ==="
if OUT="$(cd "$REPO_ROOT" && SUPERPOWERS_CAPABILITIES=native-worktree \
  "${RESOLVE[@]}" --project-root "$REPO_ROOT" --user-home "$TEST_HOME" --bundled-only)"; then
  write_json "$OUT"
  if python3 - "$JSON_FILE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
t = [x for x in d["transitions"] if x["from"] == "brainstorming" and x["on"] == "approved-architectural"][0]
assert t["to"] == "ensure-worktree"
assert "run" in d["skills"]["using-git-worktrees"]
PY
  then
    pass "SUPERPOWERS_CAPABILITIES selects native-worktree overlay"
  else
    fail "SUPERPOWERS_CAPABILITIES selects native-worktree overlay"
  fi
else
  fail "SUPERPOWERS_CAPABILITIES selects native-worktree overlay"
fi

echo "=== two-call: SessionStart resolve then run-workflow-action --id ==="
TWO="$TEST_ROOT/two-call-proj"
mkdir -p "$TWO"
TWO_HOME="$TEST_ROOT/two-call-home"
mkdir -p "$TWO_HOME"

if MAP="$(cd "$TWO" && env -u SUPERPOWERS_CAPABILITIES CURSOR_PLUGIN_ROOT="$REPO_ROOT" \
  "${RESOLVE[@]}" --project-root "$TWO" --user-home "$TWO_HOME" --detect-capabilities --capabilities native-worktree --bundled-only)"; then
  write_json "$MAP"
  if python3 - "$JSON_FILE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert "session-inject" in d["capabilities"]
assert "native-worktree" in d["capabilities"]
assert "run" in d["skills"]["ensure-worktree"]
assert "run" in d["skills"]["using-git-worktrees"]
PY
  then
    pass "two-call resolve publishes ensure-worktree and using-git-worktrees runs"
  else
    fail "two-call resolve publishes ensure-worktree and using-git-worktrees runs"
  fi
else
  fail "two-call resolve publishes ensure-worktree and using-git-worktrees runs"
fi

CAPS="$(python3 -c 'import json,sys; print(",".join(json.load(open(sys.argv[1]))["capabilities"]))' "$JSON_FILE")"

if OUT="$(cd "$TWO" && env -u SUPERPOWERS_CAPABILITIES CURSOR_PLUGIN_ROOT="$REPO_ROOT" \
  "$REPO_ROOT/scripts/run-workflow-action" --id ensure-worktree --plugin-root "$REPO_ROOT" \
  --project-root "$TWO" --user-home "$TWO_HOME" --bundled-only --capabilities "$CAPS")"; then
  write_json "$OUT"
  if python3 - "$JSON_FILE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["outcome"] == "complete"
assert d["exit_code"] == 0
assert d["argv"][0].endswith("ensure-worktree"), d["argv"]
PY
  then
    pass "two-call forwarded capabilities executes ensure-worktree"
  else
    fail "two-call forwarded capabilities executes ensure-worktree"
    echo "$OUT" | sed 's/^/    /'
  fi
else
  fail "two-call forwarded capabilities executes ensure-worktree"
  echo "${OUT:-}" | sed 's/^/    /'
fi

if OUT="$(cd "$TWO" && env -u SUPERPOWERS_CAPABILITIES CURSOR_PLUGIN_ROOT="$REPO_ROOT" \
  "$REPO_ROOT/scripts/run-workflow-action" --id using-git-worktrees --plugin-root "$REPO_ROOT" \
  --project-root "$TWO" --user-home "$TWO_HOME" --bundled-only --capabilities "$CAPS")"; then
  write_json "$OUT"
  if python3 - "$JSON_FILE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["outcome"] == "complete"
assert d["argv"][0].endswith("ensure-worktree")
PY
  then
    pass "two-call forwarded capabilities executes remapped using-git-worktrees"
  else
    fail "two-call forwarded capabilities executes remapped using-git-worktrees"
    echo "$OUT" | sed 's/^/    /'
  fi
else
  fail "two-call forwarded capabilities executes remapped using-git-worktrees"
  echo "${OUT:-}" | sed 's/^/    /'
fi

if OUT="$(cd "$TWO" && env -u SUPERPOWERS_CAPABILITIES CURSOR_PLUGIN_ROOT="$REPO_ROOT" \
  "$REPO_ROOT/scripts/run-workflow-action" --id ensure-worktree --plugin-root "$REPO_ROOT" \
  --project-root "$TWO" --user-home "$TWO_HOME" --bundled-only 2>"$TEST_ROOT/err-nofwd.txt")"; then
  fail "two-call without forwarding does not invent native-worktree"
  echo "$OUT" | sed 's/^/    /'
else
  if grep -qi 'unknown logical id' "$TEST_ROOT/err-nofwd.txt"; then
    pass "two-call without forwarding does not invent native-worktree"
  else
    fail "two-call without forwarding does not invent native-worktree"
    sed 's/^/    /' "$TEST_ROOT/err-nofwd.txt"
  fi
fi

echo "=== same-signature project overlay replaces ensure-worktree argv ==="
OVR="$TEST_ROOT/override-proj"
mkdir -p "$OVR/scripts" "$OVR/.supersuit"
cat > "$OVR/scripts/my-ensure-worktree.sh" <<'EOF'
#!/usr/bin/env bash
echo custom-ensure
exit 0
EOF
chmod +x "$OVR/scripts/my-ensure-worktree.sh"
cat > "$OVR/.supersuit/workflow.yaml" <<'EOF'
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
EOF
if OUT="$(cd "$OVR" && env -u SUPERPOWERS_CAPABILITIES \
  "$REPO_ROOT/scripts/run-workflow-action" --id ensure-worktree --plugin-root "$REPO_ROOT" \
  --project-root "$OVR" --user-home "$TEST_HOME" --capabilities native-worktree)"; then
  write_json "$OUT"
  if python3 - "$JSON_FILE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["outcome"] == "complete"
assert d["argv"][0].endswith("my-ensure-worktree.sh"), d["argv"]
PY
  then
    pass "same-signature overlay replaces ensure-worktree script"
  else
    fail "same-signature overlay replaces ensure-worktree script"
    echo "$OUT" | sed 's/^/    /'
  fi
else
  fail "same-signature overlay replaces ensure-worktree script"
  echo "${OUT:-}" | sed 's/^/    /'
fi

echo "=== default.yaml stays ungated and free of run actions ==="
if python3 - "$REPO_ROOT" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / "scripts" / "lib"))
from workflow_yaml import load_yaml
doc = load_yaml((Path(sys.argv[1]) / "workflows" / "default.yaml").read_text())
for skill_id, entry in (doc.get("skills") or {}).items():
    assert isinstance(entry, dict)
    assert "run" not in entry and "exec" not in entry, skill_id
    assert "when" not in entry, skill_id
for transition in doc.get("transitions") or []:
    assert "when" not in transition, transition
    assert "run" not in transition
print("ok")
PY
then
  pass "default.yaml stays ungated and free of run actions"
else
  fail "default.yaml stays ungated and free of run actions"
fi

if [[ "$FAILURES" -gt 0 ]]; then
  echo "FAILED: $FAILURES"
  exit 1
fi
echo "All native-worktree workflow tests passed"
exit 0
