#!/usr/bin/env bash
# Issue #12: advertised exec-hook uses the host mediator (no model argv);
# missing token stays agent-mediated; product names / SessionStart never invent
# exec-hook; allowlist still applies on the auto path.
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
EXEC="$REPO_ROOT/hooks/workflow-exec"
JSON_FILE="$TEST_ROOT/last.json"

write_json() {
  printf '%s' "$1" > "$JSON_FILE"
}

write_overlay() {
  local proj="$1"
  mkdir -p "$proj/scripts" "$proj/.supersuit"
  cat > "$proj/scripts/ensure-fixture.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${SUPERPOWERS_EXEC_MARKER:-}" ]]; then
  printf 'ran\n' > "$SUPERPOWERS_EXEC_MARKER"
fi
exit 0
EOF
  chmod +x "$proj/scripts/ensure-fixture.sh"
  cat > "$proj/.supersuit/workflow.yaml" <<'EOF'
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
  - from: ensure-fixture
    on: complete
    to: writing-plans
    when:
      capabilities:
        - exec-hook
  - from: ensure-fixture
    on: failed
    to: wait
    when:
      capabilities:
        - exec-hook
EOF
}

echo "=== hooks.json registers Claude Stop -> workflow-exec ==="
if [[ -f "$REPO_ROOT/hooks/hooks.json" ]] && node -e '
const hooks = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const stop = hooks.hooks && hooks.hooks.Stop;
if (!Array.isArray(stop) || stop.length === 0) {
  console.error("hooks.json missing Stop array");
  process.exit(1);
}
const entry = stop[0].hooks[0];
if (entry.shell !== "bash") {
  console.error(`Stop hook shell is ${JSON.stringify(entry.shell)}, expected "bash"`);
  process.exit(1);
}
if (!/run-hook\.cmd" workflow-exec$/.test(entry.command)) {
  console.error(`unexpected Stop command shape: ${entry.command}`);
  process.exit(1);
}
' "$REPO_ROOT/hooks/hooks.json"; then
  pass "hooks.json registers Claude Stop -> workflow-exec"
else
  fail "hooks.json registers Claude Stop -> workflow-exec"
fi

echo "=== advertised exec-hook auto-path executes without model argv ==="
AUTO="$TEST_ROOT/auto-proj"
write_overlay "$AUTO"
MARKER="$TEST_ROOT/auto.marker"
rm -f "$MARKER"
if [[ -x "$EXEC" ]] && OUT="$(cd "$AUTO" && SUPERPOWERS_EXEC_MARKER="$MARKER" env -u SUPERPOWERS_CAPABILITIES \
  "$EXEC" --id ensure-fixture --plugin-root "$REPO_ROOT" \
  --project-root "$AUTO" --user-home "$TEST_HOME" --capabilities exec-hook)"; then
  write_json "$OUT"
  if [[ -f "$MARKER" ]] && python3 - "$JSON_FILE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["mode"] == "auto", d
assert d["id"] == "ensure-fixture"
assert d["outcome"] == "complete"
assert d["exit_code"] == 0
assert d["argv"][0].endswith("ensure-fixture.sh"), d["argv"]
assert "exec-hook" in d.get("capabilities", [])
PY
  then
    pass "advertised exec-hook auto-path executes without model argv"
  else
    fail "advertised exec-hook auto-path executes without model argv"
    echo "    out=$OUT"
  fi
else
  fail "advertised exec-hook auto-path executes without model argv"
  echo "    exec missing or failed"
fi

echo "=== --from/--on looks up the run id and executes ==="
MARKER="$TEST_ROOT/fromon.marker"
rm -f "$MARKER"
if [[ -x "$EXEC" ]] && OUT="$(cd "$AUTO" && SUPERPOWERS_EXEC_MARKER="$MARKER" env -u SUPERPOWERS_CAPABILITIES \
  "$EXEC" --from brainstorming --on approved-architectural --plugin-root "$REPO_ROOT" \
  --project-root "$AUTO" --user-home "$TEST_HOME" --capabilities exec-hook)"; then
  write_json "$OUT"
  if [[ -f "$MARKER" ]] && python3 - "$JSON_FILE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["mode"] == "auto", d
assert d["from"] == "brainstorming"
assert d["on"] == "approved-architectural"
assert d["id"] == "ensure-fixture"
assert d["outcome"] == "complete"
PY
  then
    pass "--from/--on looks up the run id and executes"
  else
    fail "--from/--on looks up the run id and executes"
    echo "    out=$OUT"
  fi
else
  fail "--from/--on looks up the run id and executes"
fi

echo "=== missing token stays agent-mediated (no execute) ==="
MISS="$TEST_ROOT/miss-proj"
write_overlay "$MISS"
MARKER="$TEST_ROOT/miss.marker"
rm -f "$MARKER"
set +e
OUT="$(cd "$MISS" && SUPERPOWERS_EXEC_MARKER="$MARKER" env -u SUPERPOWERS_CAPABILITIES \
  "$EXEC" --id ensure-fixture --plugin-root "$REPO_ROOT" \
  --project-root "$MISS" --user-home "$TEST_HOME" 2>"$TEST_ROOT/err-miss.txt")"
STATUS=$?
set -e
write_json "${OUT:-}"
if [[ ! -f "$MARKER" ]] && [[ "$STATUS" -ne 0 ]] && python3 - "$JSON_FILE" <<'PY'
import json, sys
raw = open(sys.argv[1]).read().strip()
assert raw, "expected agent-mediated JSON"
d = json.loads(raw)
assert d["mode"] == "agent-mediated", d
assert "exec-hook" in d.get("reason", "")
PY
then
  pass "missing token stays agent-mediated (no execute)"
else
  fail "missing token stays agent-mediated (no execute)"
  echo "    status=$STATUS out=$OUT"
  sed 's/^/    /' "$TEST_ROOT/err-miss.txt" 2>/dev/null || true
fi

echo "=== agent-mediated CLI still works without exec-hook ==="
# run-workflow-action is the #10 fallback; it must still execute when the
# overlay is explicitly selected via --capabilities on that CLI.
if OUT="$(cd "$AUTO" && SUPERPOWERS_EXEC_MARKER="$TEST_ROOT/agent.marker" env -u SUPERPOWERS_CAPABILITIES \
  "$REPO_ROOT/scripts/run-workflow-action" --id ensure-fixture --plugin-root "$REPO_ROOT" \
  --project-root "$AUTO" --user-home "$TEST_HOME" --capabilities exec-hook)"; then
  write_json "$OUT"
  if python3 - "$JSON_FILE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["outcome"] == "complete"
assert d["argv"][0].endswith("ensure-fixture.sh")
PY
  then
    pass "agent-mediated CLI still works without requiring workflow-exec"
  else
    fail "agent-mediated CLI still works without requiring workflow-exec"
  fi
else
  fail "agent-mediated CLI still works without requiring workflow-exec"
fi

echo "=== product names / SessionStart env never invent exec-hook ==="
for envpair in \
  "CURSOR_PLUGIN_ROOT=$REPO_ROOT" \
  "CLAUDE_PLUGIN_ROOT=$REPO_ROOT" \
  "COPILOT_CLI=1"
do
  key="${envpair%%=*}"
  MARKER="$TEST_ROOT/probe-$key.marker"
  rm -f "$MARKER"
  set +e
  OUT="$(cd "$AUTO" && SUPERPOWERS_EXEC_MARKER="$MARKER" env -u SUPERPOWERS_CAPABILITIES \
    $envpair \
    "$EXEC" --id ensure-fixture --plugin-root "$REPO_ROOT" \
    --project-root "$AUTO" --user-home "$TEST_HOME" 2>"$TEST_ROOT/err-probe-$key.txt")"
  STATUS=$?
  set -e
  if [[ -f "$MARKER" ]]; then
    fail "product/SessionStart env $key never invents exec-hook"
    echo "    executed under $key"
    continue
  fi
  if [[ -x "$EXEC" ]] && printf '%s' "${OUT:-}" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["mode"]=="agent-mediated"'; then
    pass "product/SessionStart env $key never invents exec-hook"
  else
    fail "product/SessionStart env $key never invents exec-hook"
    echo "    status=$STATUS out=$OUT"
  fi
done

if OUT="$(cd "$AUTO" && env -u SUPERPOWERS_CAPABILITIES \
  "${RESOLVE[@]}" --project-root "$AUTO" --user-home "$TEST_HOME" \
  --capabilities Cursor,Claude,Codex,sessionStart)"; then
  write_json "$OUT"
  if python3 - "$JSON_FILE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert "exec-hook" not in d.get("capabilities", [])
t = [x for x in d["transitions"] if x["from"] == "brainstorming" and x["on"] == "approved-architectural"][0]
assert t["to"] == "writing-plans", t
assert "ensure-fixture" not in d["skills"] or "run" not in d["skills"].get("ensure-fixture", {})
PY
  then
    pass "product-name --capabilities tokens never invent exec-hook"
  else
    fail "product-name --capabilities tokens never invent exec-hook"
  fi
else
  fail "product-name --capabilities tokens never invent exec-hook"
fi

echo "=== allowlist still enforced on auto path ==="
ESC="$TEST_ROOT/escape-proj"
mkdir -p "$ESC/.supersuit"
cat > "$ESC/.supersuit/workflow.yaml" <<'EOF'
version: 1
skills:
  escaped-run:
    run:
      argv:
        - /bin/true
      allow:
        - project
    when:
      capabilities:
        - exec-hook
transitions:
  - from: brainstorming
    on: approved-architectural
    to: escaped-run
    when:
      capabilities:
        - exec-hook
EOF
set +e
OUT="$(cd "$ESC" && env -u SUPERPOWERS_CAPABILITIES \
  "$EXEC" --id escaped-run --plugin-root "$REPO_ROOT" \
  --project-root "$ESC" --user-home "$TEST_HOME" --capabilities exec-hook \
  2>"$TEST_ROOT/err-escape.txt")"
STATUS=$?
set -e
if [[ "$STATUS" -ne 0 ]] && grep -Eiq 'allow|escape|outside|not under|project' "$TEST_ROOT/err-escape.txt"; then
  pass "allowlist still enforced on auto path"
else
  # resolve-time validation may reject before exec; that is also enforcement
  if [[ "$STATUS" -ne 0 ]] && grep -Eiq 'allow|outside|/bin/true|argv' "$TEST_ROOT/err-escape.txt"; then
    pass "allowlist still enforced on auto path"
  else
    fail "allowlist still enforced on auto path"
    echo "    status=$STATUS out=$OUT"
    sed 's/^/    /' "$TEST_ROOT/err-escape.txt"
  fi
fi

echo "=== two-call: SessionStart detect + forwarded capabilities ==="
TWO="$TEST_ROOT/two-call-proj"
write_overlay "$TWO"
TWO_HOME="$TEST_ROOT/two-home"
mkdir -p "$TWO_HOME"
if OUT="$(cd "$TWO" && env -u SUPERPOWERS_CAPABILITIES \
  CURSOR_PLUGIN_ROOT="$REPO_ROOT" SUPERPOWERS_CAPABILITIES=exec-hook \
  "${RESOLVE[@]}" --project-root "$TWO" --user-home "$TWO_HOME" --detect-capabilities)"; then
  write_json "$OUT"
  if python3 - "$JSON_FILE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert "exec-hook" in d.get("capabilities", [])
assert "session-inject" in d.get("capabilities", [])
assert "run" in d["skills"]["ensure-fixture"]
t = [x for x in d["transitions"] if x["from"] == "brainstorming" and x["on"] == "approved-architectural"][0]
assert t["to"] == "ensure-fixture"
PY
  then
    pass "two-call resolve publishes exec-hook + gated run"
  else
    fail "two-call resolve publishes exec-hook + gated run"
  fi
else
  fail "two-call resolve publishes exec-hook + gated run"
fi

CAPS="$(python3 -c 'import json,sys; print(",".join(json.load(open(sys.argv[1]))["capabilities"]))' "$JSON_FILE")"
MARKER="$TEST_ROOT/two.marker"
rm -f "$MARKER"
if [[ -x "$EXEC" ]] && OUT="$(cd "$TWO" && SUPERPOWERS_EXEC_MARKER="$MARKER" env -u SUPERPOWERS_CAPABILITIES \
  CURSOR_PLUGIN_ROOT="$REPO_ROOT" \
  "$EXEC" --id ensure-fixture --plugin-root "$REPO_ROOT" \
  --project-root "$TWO" --user-home "$TWO_HOME" --capabilities "$CAPS")"; then
  write_json "$OUT"
  if [[ -f "$MARKER" ]] && python3 - "$JSON_FILE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["mode"] == "auto"
assert d["outcome"] == "complete"
assert "exec-hook" in d.get("capabilities", [])
assert "session-inject" in d.get("capabilities", [])
PY
  then
    pass "two-call forwarded capabilities auto-executes"
  else
    fail "two-call forwarded capabilities auto-executes"
    echo "    out=$OUT"
  fi
else
  fail "two-call forwarded capabilities auto-executes"
fi

MARKER="$TEST_ROOT/nofwd.marker"
rm -f "$MARKER"
set +e
OUT="$(cd "$TWO" && SUPERPOWERS_EXEC_MARKER="$MARKER" env -u SUPERPOWERS_CAPABILITIES \
  CURSOR_PLUGIN_ROOT="$REPO_ROOT" \
  "$EXEC" --id ensure-fixture --plugin-root "$REPO_ROOT" \
  --project-root "$TWO" --user-home "$TWO_HOME" 2>"$TEST_ROOT/err-nofwd.txt")"
STATUS=$?
set -e
if [[ -f "$MARKER" ]]; then
  fail "two-call without forwarding does not invent exec-hook"
  echo "    executed without forwarded capabilities"
elif printf '%s' "${OUT:-}" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["mode"]=="agent-mediated"'; then
  pass "two-call without forwarding does not invent exec-hook"
else
  fail "two-call without forwarding does not invent exec-hook"
  echo "    status=$STATUS out=$OUT"
  sed 's/^/    /' "$TEST_ROOT/err-nofwd.txt"
fi

echo "=== overlays can keep baseline skill edges without exec-hook ==="
if OUT="$(cd "$AUTO" && env -u SUPERPOWERS_CAPABILITIES \
  "${RESOLVE[@]}" --project-root "$AUTO" --user-home "$TEST_HOME")"; then
  write_json "$OUT"
  if python3 - "$JSON_FILE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert "exec-hook" not in d.get("capabilities", [])
t = [x for x in d["transitions"] if x["from"] == "brainstorming" and x["on"] == "approved-architectural"][0]
assert t["to"] == "writing-plans", t
assert "ensure-fixture" not in d["skills"] or "run" not in d["skills"].get("ensure-fixture", {})
PY
  then
    pass "overlays keep baseline skill edges without exec-hook"
  else
    fail "overlays keep baseline skill edges without exec-hook"
  fi
else
  fail "overlays keep baseline skill edges without exec-hook"
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

echo "=== hook stdin idle without payload does not execute ==="
MARKER="$TEST_ROOT/idle.marker"
rm -f "$MARKER"
if [[ -x "$EXEC" ]] && OUT="$(cd "$AUTO" && SUPERPOWERS_EXEC_MARKER="$MARKER" env -u SUPERPOWERS_CAPABILITIES \
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
  "$EXEC" --plugin-root "$REPO_ROOT" --project-root "$AUTO" --user-home "$TEST_HOME" \
  --capabilities exec-hook <<'STDIN'
{"session_id":"t","transcript_path":"/tmp/t.jsonl","stop_hook_active":false}
STDIN
)"; then
  if [[ -f "$MARKER" ]]; then
    fail "hook stdin idle without payload does not execute"
  else
    pass "hook stdin idle without payload does not execute"
  fi
else
  # idle may exit 0 with empty/JSON idle; non-zero is a fail
  if [[ ! -f "$MARKER" ]] && [[ -x "$EXEC" ]]; then
    pass "hook stdin idle without payload does not execute"
  else
    fail "hook stdin idle without payload does not execute"
  fi
fi

echo "=== idle Stop + invalid overlay + exec-hook does not kill the session ==="
BAD="$TEST_ROOT/invalid-overlay-proj"
mkdir -p "$BAD/.supersuit"
printf 'version: "nope"\n' > "$BAD/.supersuit/workflow.yaml"
set +e
OUT="$(cd "$BAD" && env -u SUPERPOWERS_CAPABILITIES \
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT" SUPERPOWERS_CAPABILITIES=exec-hook \
  "$EXEC" --plugin-root "$REPO_ROOT" --project-root "$BAD" --user-home "$TEST_HOME" \
  --capabilities exec-hook 2>"$TEST_ROOT/err-idle-invalid.txt" <<'STDIN'
{"session_id":"s1","transcript_path":"/tmp/t.jsonl","stop_hook_active":false}
STDIN
)"
STATUS=$?
set -e
if [[ "$STATUS" -eq 0 ]] && ! grep -q "unsupported version" "$TEST_ROOT/err-idle-invalid.txt"; then
  pass "idle Stop + invalid overlay exits 0 without resolving"
else
  fail "idle Stop + invalid overlay exits 0 without resolving"
  echo "    status=$STATUS out=$OUT"
  sed 's/^/    /' "$TEST_ROOT/err-idle-invalid.txt"
fi

echo "=== hook-event failed child still emits block JSON and exits 0 ==="
FAILP="$TEST_ROOT/fail-child-proj"
write_overlay "$FAILP"
cat > "$FAILP/scripts/ensure-fixture.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${SUPERPOWERS_EXEC_MARKER:-}" ]]; then
  printf 'ran\n' > "$SUPERPOWERS_EXEC_MARKER"
fi
exit 7
EOF
chmod +x "$FAILP/scripts/ensure-fixture.sh"
MARKER="$TEST_ROOT/fail-child.marker"
rm -f "$MARKER"
set +e
OUT="$(cd "$FAILP" && SUPERPOWERS_EXEC_MARKER="$MARKER" env -u SUPERPOWERS_CAPABILITIES \
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
  "$EXEC" --plugin-root "$REPO_ROOT" --project-root "$FAILP" --user-home "$TEST_HOME" \
  --capabilities exec-hook 2>"$TEST_ROOT/err-fail-child.txt" <<'STDIN'
{"session_id":"s-fail","transcript_path":"/tmp/t.jsonl","stop_hook_active":false,"id":"ensure-fixture"}
STDIN
)"
STATUS=$?
set -e
write_json "${OUT:-}"
if [[ "$STATUS" -eq 0 ]] && [[ -f "$MARKER" ]] && python3 - "$JSON_FILE" <<'PY'
import json, sys
outer = json.load(open(sys.argv[1]))
assert outer.get("decision") == "block", outer
ctx = outer["hookSpecificOutput"]["additionalContext"]
start = ctx.index("<WORKFLOW_EXEC_RESULT>") + len("<WORKFLOW_EXEC_RESULT>")
end = ctx.index("</WORKFLOW_EXEC_RESULT>")
inner = json.loads(ctx[start:end].strip())
assert inner["mode"] == "auto", inner
assert inner["exit_code"] == 7, inner
assert inner["outcome"] == "failed", inner
PY
then
  pass "hook-event failed child prints block JSON and exits 0"
else
  fail "hook-event failed child prints block JSON and exits 0"
  echo "    status=$STATUS out=$OUT"
  sed 's/^/    /' "$TEST_ROOT/err-fail-child.txt"
fi

echo "=== real Claude Stop stdin + pending handoff auto-executes ==="
PEND="$TEST_ROOT/pending-stop-proj"
write_overlay "$PEND"
MARKER="$TEST_ROOT/pending-stop.marker"
rm -f "$MARKER"
if ! OUT="$(cd "$PEND" && env -u SUPERPOWERS_CAPABILITIES \
  "$EXEC" --queue --from brainstorming --on approved-architectural \
  --plugin-root "$REPO_ROOT" --project-root "$PEND" --user-home "$TEST_HOME" \
  --capabilities exec-hook)"; then
  fail "real Claude Stop stdin + pending handoff auto-executes"
  echo "    --queue failed: $OUT"
else
  write_json "$OUT"
  if [[ -f "$PEND/.supersuit/pending-handoff.json" ]] && python3 - "$JSON_FILE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["mode"] == "queued", d
assert d["from"] == "brainstorming"
assert d["on"] == "approved-architectural"
PY
  then
    set +e
    OUT="$(cd "$PEND" && SUPERPOWERS_EXEC_MARKER="$MARKER" env -u SUPERPOWERS_CAPABILITIES \
      CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
      "$EXEC" --plugin-root "$REPO_ROOT" --project-root "$PEND" --user-home "$TEST_HOME" \
      --capabilities exec-hook 2>"$TEST_ROOT/err-pending-stop.txt" <<'STDIN'
{"session_id":"abc-123","transcript_path":"/tmp/transcript.jsonl","stop_hook_active":false}
STDIN
)"
    STATUS=$?
    set -e
    write_json "${OUT:-}"
    if [[ "$STATUS" -eq 0 ]] && [[ -f "$MARKER" ]] && [[ ! -f "$PEND/.supersuit/pending-handoff.json" ]] && python3 - "$JSON_FILE" <<'PY'
import json, sys
outer = json.load(open(sys.argv[1]))
assert outer.get("decision") == "block", outer
ctx = outer["hookSpecificOutput"]["additionalContext"]
start = ctx.index("<WORKFLOW_EXEC_RESULT>") + len("<WORKFLOW_EXEC_RESULT>")
end = ctx.index("</WORKFLOW_EXEC_RESULT>")
inner = json.loads(ctx[start:end].strip())
assert inner["mode"] == "auto", inner
assert inner["id"] == "ensure-fixture"
assert inner["from"] == "brainstorming"
assert inner["on"] == "approved-architectural"
assert inner["outcome"] == "complete"
PY
    then
      pass "real Claude Stop stdin + pending handoff auto-executes"
    else
      fail "real Claude Stop stdin + pending handoff auto-executes"
      echo "    status=$STATUS out=$OUT"
      sed 's/^/    /' "$TEST_ROOT/err-pending-stop.txt"
    fi
  else
    fail "real Claude Stop stdin + pending handoff auto-executes"
    echo "    --queue did not write pending-handoff.json: $OUT"
  fi
fi

echo "=== HOST_EXEC names pending-handoff + Stop, not Stop-alone ==="
if grep -q 'pending-handoff' "$REPO_ROOT/hooks/session-start" &&
  grep -q -- '--queue' "$REPO_ROOT/hooks/session-start" &&
  ! grep -q 'Claude Code: Stop hook\.' "$REPO_ROOT/hooks/session-start"
then
  pass "HOST_EXEC names pending-handoff queue, not Stop-alone"
else
  fail "HOST_EXEC names pending-handoff queue, not Stop-alone"
fi

if [[ "$FAILURES" -gt 0 ]]; then
  echo "FAILED: $FAILURES"
  exit 1
fi
echo "All exec-hook workflow tests passed"
exit 0
