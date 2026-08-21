#!/usr/bin/env bash
# Issues #8 / #9: advertised native-canvas prefers the native visual surface;
# missing capability keeps the companion-server portable default;
# declined or unavailable is text-only; never infer from product names.
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
SELECT="$REPO_ROOT/scripts/select-visual-surface"

write_json() {
  printf '%s' "$1" > "$JSON_FILE"
}

echo "=== select-visual-surface: advertised native-canvas prefers native ==="
if [[ -x "$SELECT" ]] && OUT="$(env -u SUPERPOWERS_CAPABILITIES "$SELECT" --accepted yes --capabilities native-canvas)"; then
  write_json "$OUT"
  if python3 - "$JSON_FILE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["surface"] == "native", d
PY
  then
    pass "advertised native-canvas + accepted -> native"
  else
    fail "advertised native-canvas + accepted -> native"
  fi
else
  fail "advertised native-canvas + accepted -> native"
fi

echo "=== select-visual-surface: no advertisement falls back to companion ==="
if [[ -x "$SELECT" ]]; then
  set +e
  OUT="$(env -u SUPERPOWERS_CAPABILITIES "$SELECT" --accepted yes)"
  STATUS=$?
  set -e
  write_json "$OUT"
  if [[ "$STATUS" -eq 10 ]] && python3 - "$JSON_FILE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["surface"] == "companion", d
PY
  then
    pass "no advertisement + accepted -> companion"
  else
    fail "no advertisement + accepted -> companion"
    echo "    status=$STATUS out=$OUT"
  fi
else
  fail "no advertisement + accepted -> companion"
fi

echo "=== select-visual-surface: declined is text-only ==="
if [[ -x "$SELECT" ]] && OUT="$(env -u SUPERPOWERS_CAPABILITIES "$SELECT" --accepted no --capabilities native-canvas)"; then
  write_json "$OUT"
  STATUS=0
else
  STATUS=$?
  OUT="${OUT:-}"
fi
if [[ "$STATUS" -eq 20 ]] && printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["surface"]=="text"'; then
  pass "declined -> text"
else
  fail "declined -> text"
  echo "    status=$STATUS out=$OUT"
fi

echo "=== select-visual-surface: native unavailable falls back to companion ==="
if [[ -x "$SELECT" ]]; then
  set +e
  OUT="$(env -u SUPERPOWERS_CAPABILITIES "$SELECT" --accepted yes --capabilities native-canvas --available no)"
  STATUS=$?
  set -e
  write_json "$OUT"
  if [[ "$STATUS" -eq 10 ]] && python3 - "$JSON_FILE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["surface"] == "companion", d
PY
  then
    pass "native unavailable -> companion"
  else
    fail "native unavailable -> companion"
    echo "    status=$STATUS out=$OUT"
  fi
else
  fail "native unavailable -> companion"
fi

echo "=== select-visual-surface: nothing available is text-only ==="
if [[ -x "$SELECT" ]]; then
  if OUT="$(env -u SUPERPOWERS_CAPABILITIES "$SELECT" --accepted yes --available no)"; then
    fail "nothing available is text-only (expected exit 20)"
    echo "    out=$OUT"
  else
    STATUS=$?
    if [[ "$STATUS" -eq 20 ]] && printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["surface"]=="text"'; then
      pass "nothing available -> text"
    else
      fail "nothing available is text-only"
      echo "    status=$STATUS out=$OUT"
    fi
  fi
else
  fail "nothing available is text-only"
fi

echo "=== select-visual-surface: never infer native-canvas from harness names ==="
for envspec in \
  "CURSOR_PLUGIN_ROOT=/tmp" \
  "CLAUDE_PLUGIN_ROOT=/tmp" \
  "COPILOT_CLI=1"
do
  key="${envspec%%=*}"
  if [[ -x "$SELECT" ]]; then
    set +e
    OUT="$(env -u SUPERPOWERS_CAPABILITIES $envspec "$SELECT" --accepted yes --detect-capabilities)"
    STATUS=$?
    set -e
    write_json "$OUT"
    if [[ "$STATUS" -eq 10 ]] && python3 - "$JSON_FILE" <<PY
import json, sys
d = json.load(open(sys.argv[1]))
assert d["surface"] == "companion", d
PY
    then
      pass "detect with $key does not invent native-canvas"
    else
      fail "detect with $key does not invent native-canvas"
      echo "    status=$STATUS out=$OUT"
    fi
  else
    fail "detect with $key does not invent native-canvas"
  fi
done

echo "=== product-name strings are not treated as advertised capabilities ==="
if [[ -x "$SELECT" ]]; then
  set +e
  OUT="$(env -u SUPERPOWERS_CAPABILITIES "$SELECT" --accepted yes --capabilities Cursor,Claude,Codex)"
  STATUS=$?
  set -e
  write_json "$OUT"
  if [[ "$STATUS" -eq 10 ]] && python3 - "$JSON_FILE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["surface"] == "companion", d
PY
  then
    pass "product names in --capabilities do not select native"
  else
    fail "product names in --capabilities do not select native"
    echo "    status=$STATUS out=$OUT"
  fi
else
  fail "product names in --capabilities do not select native"
fi

echo "=== missing capability keeps companion identity visual-surface ==="
if OUT="$(cd "$REPO_ROOT" && env -u SUPERPOWERS_CAPABILITIES -u CURSOR_PLUGIN_ROOT -u CLAUDE_PLUGIN_ROOT -u COPILOT_CLI \
  "${RESOLVE[@]}" --project-root "$REPO_ROOT" --user-home "$TEST_HOME")"; then
  write_json "$OUT"
  if python3 - "$JSON_FILE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert "native-canvas" not in d.get("capabilities", [])
vs = d["skills"].get("visual-surface", {})
assert "run" not in vs, vs
assert "path" not in vs, vs
PY
  then
    pass "missing capability keeps companion identity visual-surface"
  else
    fail "missing capability keeps companion identity visual-surface"
  fi
else
  fail "missing capability keeps companion identity visual-surface"
fi

echo "=== missing-capability-probe does not invent native-canvas ==="
if OUT="$(cd "$REPO_ROOT" && env -u SUPERPOWERS_CAPABILITIES -u CURSOR_PLUGIN_ROOT -u CLAUDE_PLUGIN_ROOT -u COPILOT_CLI \
  "${RESOLVE[@]}" --project-root "$REPO_ROOT" --user-home "$TEST_HOME" --detect-capabilities --bundled-only)"; then
  write_json "$OUT"
  if python3 - "$JSON_FILE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("capabilities") == []
vs = d["skills"].get("visual-surface", {})
assert "run" not in vs
PY
  then
    pass "missing-capability-probe keeps companion baseline"
  else
    fail "missing-capability-probe keeps companion baseline"
  fi
else
  fail "missing-capability-probe keeps companion baseline"
fi

echo "=== Cursor env alone does not invent native-canvas ==="
if OUT="$(cd "$REPO_ROOT" && env -u SUPERPOWERS_CAPABILITIES CURSOR_PLUGIN_ROOT=/tmp \
  "${RESOLVE[@]}" --project-root "$REPO_ROOT" --user-home "$TEST_HOME" --detect-capabilities --bundled-only)"; then
  write_json "$OUT"
  if python3 - "$JSON_FILE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("capabilities") == ["session-inject"]
assert "native-canvas" not in d.get("capabilities", [])
vs = d["skills"].get("visual-surface", {})
assert "run" not in vs
PY
  then
    pass "Cursor env alone does not invent native-canvas"
  else
    fail "Cursor env alone does not invent native-canvas"
  fi
else
  fail "Cursor env alone does not invent native-canvas"
fi

echo "=== advertised native-canvas remaps visual-surface to select run ==="
if OUT="$(cd "$REPO_ROOT" && env -u SUPERPOWERS_CAPABILITIES \
  "${RESOLVE[@]}" --project-root "$REPO_ROOT" --user-home "$TEST_HOME" --capabilities native-canvas --bundled-only)"; then
  write_json "$OUT"
  if python3 - "$JSON_FILE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert "native-canvas" in d["capabilities"]
vs = d["skills"]["visual-surface"]
assert "when" not in vs
assert "run" in vs, vs
assert vs["run"]["argv"][0].endswith("select-visual-surface"), vs
assert vs["run"]["outcomes"]["0"] == "native"
assert vs["run"]["outcomes"]["10"] == "companion"
assert vs["run"]["outcomes"]["20"] == "text"
for on in ("native", "companion", "text"):
    edge = [x for x in d["transitions"] if x["from"] == "visual-surface" and x["on"] == on][0]
    assert edge["to"] is None, edge
    assert "when" not in edge
# Architectural graph stays Superpowers-shaped unless native-worktree is also on.
arch = [x for x in d["transitions"] if x["from"] == "brainstorming" and x["on"] == "approved-architectural"][0]
assert arch["to"] == "writing-plans", arch
PY
  then
    pass "advertised native-canvas remaps visual-surface to select run"
  else
    fail "advertised native-canvas remaps visual-surface to select run"
  fi
else
  fail "advertised native-canvas remaps visual-surface to select run"
fi

echo "=== SUPERPOWERS_CAPABILITIES=native-canvas selects gated overlay ==="
if OUT="$(cd "$REPO_ROOT" && SUPERPOWERS_CAPABILITIES=native-canvas \
  "${RESOLVE[@]}" --project-root "$REPO_ROOT" --user-home "$TEST_HOME" --bundled-only)"; then
  write_json "$OUT"
  if python3 - "$JSON_FILE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert "run" in d["skills"]["visual-surface"]
PY
  then
    pass "SUPERPOWERS_CAPABILITIES selects native-canvas overlay"
  else
    fail "SUPERPOWERS_CAPABILITIES selects native-canvas overlay"
  fi
else
  fail "SUPERPOWERS_CAPABILITIES selects native-canvas overlay"
fi

echo "=== two-call: SessionStart resolve then run-workflow-action --id ==="
TWO="$TEST_ROOT/two-call-proj"
mkdir -p "$TWO"
TWO_HOME="$TEST_ROOT/two-call-home"
mkdir -p "$TWO_HOME"

if MAP="$(cd "$TWO" && env -u SUPERPOWERS_CAPABILITIES CURSOR_PLUGIN_ROOT="$REPO_ROOT" \
  "${RESOLVE[@]}" --project-root "$TWO" --user-home "$TWO_HOME" --detect-capabilities --capabilities native-canvas --bundled-only)"; then
  write_json "$MAP"
  if python3 - "$JSON_FILE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert "session-inject" in d["capabilities"]
assert "native-canvas" in d["capabilities"]
assert "run" in d["skills"]["visual-surface"]
PY
  then
    pass "two-call resolve publishes visual-surface run"
  else
    fail "two-call resolve publishes visual-surface run"
  fi
else
  fail "two-call resolve publishes visual-surface run"
fi

CAPS="$(python3 -c 'import json,sys; print(",".join(json.load(open(sys.argv[1]))["capabilities"]))' "$JSON_FILE")"

if OUT="$(cd "$TWO" && env -u SUPERPOWERS_CAPABILITIES CURSOR_PLUGIN_ROOT="$REPO_ROOT" \
  "$REPO_ROOT/scripts/run-workflow-action" --id visual-surface --plugin-root "$REPO_ROOT" \
  --project-root "$TWO" --user-home "$TWO_HOME" --bundled-only --capabilities "$CAPS")"; then
  write_json "$OUT"
  if python3 - "$JSON_FILE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["outcome"] == "native", d
assert d["exit_code"] == 0
assert d["argv"][0].endswith("select-visual-surface"), d["argv"]
PY
  then
    pass "two-call forwarded capabilities executes native visual-surface"
  else
    fail "two-call forwarded capabilities executes native visual-surface"
    echo "$OUT" | sed 's/^/    /'
  fi
else
  fail "two-call forwarded capabilities executes native visual-surface"
  echo "${OUT:-}" | sed 's/^/    /'
fi

if OUT="$(cd "$TWO" && env -u SUPERPOWERS_CAPABILITIES CURSOR_PLUGIN_ROOT="$REPO_ROOT" \
  "$REPO_ROOT/scripts/run-workflow-action" --id visual-surface --plugin-root "$REPO_ROOT" \
  --project-root "$TWO" --user-home "$TWO_HOME" --bundled-only 2>"$TEST_ROOT/err-nofwd.txt")"; then
  fail "two-call without forwarding does not invent native-canvas"
  echo "$OUT" | sed 's/^/    /'
else
  if grep -qi 'not a run/exec action' "$TEST_ROOT/err-nofwd.txt"; then
    pass "two-call without forwarding does not invent native-canvas"
  else
    fail "two-call without forwarding does not invent native-canvas"
    sed 's/^/    /' "$TEST_ROOT/err-nofwd.txt"
  fi
fi

echo "=== same-signature project overlay replaces select-visual-surface argv ==="
OVR="$TEST_ROOT/override-proj"
mkdir -p "$OVR/scripts" "$OVR/.supersuit"
cat > "$OVR/scripts/my-select-visual-surface.sh" <<'EOF'
#!/usr/bin/env bash
echo '{"surface":"native","custom":true}'
exit 0
EOF
chmod +x "$OVR/scripts/my-select-visual-surface.sh"
cat > "$OVR/.supersuit/workflow.yaml" <<'EOF'
version: 1
skills:
  visual-surface:
    run:
      argv:
        - scripts/my-select-visual-surface.sh
      allow:
        - project
      outcomes:
        0: native
        10: companion
        20: text
    when:
      capabilities:
        - native-canvas
EOF
if OUT="$(cd "$OVR" && env -u SUPERPOWERS_CAPABILITIES \
  "$REPO_ROOT/scripts/run-workflow-action" --id visual-surface --plugin-root "$REPO_ROOT" \
  --project-root "$OVR" --user-home "$TEST_HOME" --capabilities native-canvas)"; then
  write_json "$OUT"
  if python3 - "$JSON_FILE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["outcome"] == "native"
assert d["argv"][0].endswith("my-select-visual-surface.sh"), d["argv"]
PY
  then
    pass "same-signature overlay replaces select-visual-surface script"
  else
    fail "same-signature overlay replaces select-visual-surface script"
    echo "$OUT" | sed 's/^/    /'
  fi
else
  fail "same-signature overlay replaces select-visual-surface script"
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

echo "=== brainstorming policy stays product-agnostic ==="
SKILL="$REPO_ROOT/skills/brainstorming/SKILL.md"
if [[ -f "$SKILL" ]] && python3 - "$SKILL" <<'PY'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
# Quoted user-facing offer must stay product-agnostic.
section = re.split(r"^## ", text, flags=re.M)
visual = next((s for s in section if s.startswith("Visual Surface")), "")
assert visual, "missing ## Visual Surface section"
quoted = " ".join(re.findall(r"^> .*$", visual, flags=re.M)).lower()
assert quoted, "missing quoted offer"
assert "html server" not in quoted
assert "start the server" not in quoted
assert "canvas" not in quoted
assert "visual surface" in quoted
# Policy body may mention Canvas only as a thing not to name in the offer.
assert "follow `supersuit:visual-surface`" in visual or "supersuit:visual-surface" in visual
# Policy pointers
assert "visual-surface" in text
# Red Flags table must remain (do not rewrite persuasion content)
assert "| Thought | Reality |" in text
print("ok")
PY
then
  pass "brainstorming policy is product-agnostic Visual Surface"
else
  fail "brainstorming policy is product-agnostic Visual Surface"
fi

echo "=== visual-surface skill documents advertise + never-infer contract ==="
VS_SKILL="$REPO_ROOT/skills/visual-surface/SKILL.md"
if [[ -f "$VS_SKILL" ]] && python3 - "$VS_SKILL" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text().lower()
assert "native-canvas" in text
assert "companion" in text
assert "text-only" in text or "text only" in text
assert "never infer" in text or "do not infer" in text
assert "superpowers_capabilities" in text
assert "cursor" in text  # named only as a counter-example for inference
print("ok")
PY
then
  pass "visual-surface skill documents the ladder contract"
else
  fail "visual-surface skill documents the ladder contract"
fi

if [[ "$FAILURES" -gt 0 ]]; then
  echo "FAILED: $FAILURES"
  exit 1
fi
echo "All visual-surface workflow tests passed"
exit 0
