#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK_UNDER_TEST="$REPO_ROOT/hooks/session-start"
WRAPPER_UNDER_TEST="$REPO_ROOT/hooks/run-hook.cmd"

FAILURES=0
TEST_ROOT="$(mktemp -d)"

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

pass() {
    echo "  [PASS] $1"
}

fail() {
    echo "  [FAIL] $1"
    FAILURES=$((FAILURES + 1))
}

make_home() {
    local name="$1"
    local home="$TEST_ROOT/$name/home"
    mkdir -p "$home"
    printf '%s\n' "$home"
}

assert_command_output() {
    local description="$1"
    local shape="$2"
    local contains="$3"
    local not_contains="$4"
    local home="$5"
    shift 5

    local output
    if ! output="$(env -i PATH="${PATH:-}" HOME="$home" "$@" 2>&1)"; then
        fail "$description"
        echo "    hook exited non-zero"
        echo "$output" | sed 's/^/      /'
        return
    fi

    if printf '%s' "$output" | \
        EXPECT_SHAPE="$shape" \
        EXPECT_CONTAINS="$contains" \
        EXPECT_NOT_CONTAINS="$not_contains" \
        node -e '
const fs = require("fs");

const input = fs.readFileSync(0, "utf8");
let payload;
try {
  payload = JSON.parse(input);
} catch (error) {
  console.error(`invalid JSON: ${error.message}`);
  process.exit(1);
}

function hasOwn(object, key) {
  return Object.prototype.hasOwnProperty.call(object, key);
}

function fail(message) {
  console.error(message);
  process.exit(1);
}

const shape = process.env.EXPECT_SHAPE;
let context;

if (shape === "nested") {
  if (!hasOwn(payload, "hookSpecificOutput")) {
    fail("missing hookSpecificOutput");
  }
  if (hasOwn(payload, "additional_context") || hasOwn(payload, "additionalContext")) {
    fail("nested output also included a top-level context field");
  }
  const hookOutput = payload.hookSpecificOutput;
  if (!hookOutput || typeof hookOutput !== "object" || Array.isArray(hookOutput)) {
    fail("hookSpecificOutput is not an object");
  }
  if (hookOutput.hookEventName !== "SessionStart") {
    fail(`unexpected hookEventName: ${hookOutput.hookEventName}`);
  }
  context = hookOutput.additionalContext;
} else if (shape === "cursor") {
  if (hasOwn(payload, "hookSpecificOutput")) {
    fail("cursor output included hookSpecificOutput");
  }
  if (!hasOwn(payload, "additional_context")) {
    fail("cursor output missing additional_context");
  }
  if (hasOwn(payload, "additionalContext")) {
    fail("cursor output included additionalContext");
  }
  context = payload.additional_context;
} else if (shape === "sdk") {
  if (hasOwn(payload, "hookSpecificOutput")) {
    fail("sdk output included hookSpecificOutput");
  }
  if (!hasOwn(payload, "additionalContext")) {
    fail("sdk output missing additionalContext");
  }
  if (hasOwn(payload, "additional_context")) {
    fail("sdk output included additional_context");
  }
  context = payload.additionalContext;
} else {
  fail(`unknown expected shape: ${shape}`);
}

if (typeof context !== "string" || context.trim() === "") {
  fail("injected context was empty");
}

const expectedTexts = (process.env.EXPECT_CONTAINS || "")
  .split("\u001f")
  .filter(Boolean);
for (const expectedText of expectedTexts) {
  if (!context.includes(expectedText)) {
    fail(`context did not contain expected text: ${expectedText}`);
  }
}

const forbiddenTexts = (process.env.EXPECT_NOT_CONTAINS || "")
  .split("\u001f")
  .filter(Boolean);
for (const forbiddenText of forbiddenTexts) {
  if (context.includes(forbiddenText)) {
    fail(`context contained forbidden text: ${forbiddenText}`);
  }
}
'; then
        pass "$description"
    else
        fail "$description"
        echo "    output:"
        echo "$output" | sed 's/^/      /'
    fi
}

echo "SessionStart hook output tests"

# Registration shape: the hook must declare shell:"bash" so Claude Code on
# Windows dispatches via Git Bash (or fails with an actionable error) instead
# of PowerShell/cmd.exe, whose parsers break on the quoted command string
# (PowerShell ParserError; cmd.exe quote-stripping on paths with metacharacters).
if node -e '
const hooks = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const entry = hooks.hooks.SessionStart[0].hooks[0];
if (entry.shell !== "bash") {
  console.error(`SessionStart hook shell is ${JSON.stringify(entry.shell)}, expected "bash"`);
  process.exit(1);
}
if (!/run-hook\.cmd" session-start$/.test(entry.command)) {
  console.error(`unexpected SessionStart command shape: ${entry.command}`);
  process.exit(1);
}
' "$REPO_ROOT/hooks/hooks.json"; then
    pass "hooks.json registers SessionStart with shell:bash dispatch"
else
    fail "hooks.json registers SessionStart with shell:bash dispatch"
fi

claude_home="$(make_home claude-code)"
assert_command_output \
    "Claude Code emits nested SessionStart additionalContext" \
    "nested" \
    "" \
    "" \
    "$claude_home" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    bash "$HOOK_UNDER_TEST"

wrapper_home="$(make_home run-hook-wrapper)"
assert_command_output \
    "run-hook.cmd wrapper dispatches to the named session-start script" \
    "nested" \
    "" \
    "" \
    "$wrapper_home" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    bash "$WRAPPER_UNDER_TEST" session-start

cursor_home="$(make_home cursor)"
assert_command_output \
    "Cursor emits top-level additional_context only" \
    "cursor" \
    "" \
    "" \
    "$cursor_home" \
    CURSOR_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    bash "$HOOK_UNDER_TEST"

copilot_home="$(make_home copilot-cli)"
assert_command_output \
    "Copilot CLI emits top-level additionalContext only" \
    "sdk" \
    "" \
    "" \
    "$copilot_home" \
    COPILOT_CLI=1 \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    bash "$HOOK_UNDER_TEST"

legacy_home="$(make_home legacy-warning-removed)"
mkdir -p "$legacy_home/.config/superpowers/skills"
assert_command_output \
    "SessionStart omits obsolete legacy custom-skill warning" \
    "nested" \
    "" \
    "Superpowers now uses"$'\037'"~/.config/superpowers/skills"$'\037'"~/.claude/skills"$'\037'"legacy" \
    "$legacy_home" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    bash "$HOOK_UNDER_TEST"

echo "SessionStart workflow map injection tests"

assert_command_output \
    "Cursor injects WORKFLOW_MAP with resolved transitions" \
    "cursor" \
    "WORKFLOW_MAP"$'\037'"approved-architectural"$'\037'"\"capabilities\""$'\037'"session-inject"$'\037'"run-workflow-action" \
    "\"native-canvas\""$'\037'"\"to\": \"ensure-worktree\""$'\037'"\"exec-hook\""$'\037'"HOST_EXEC" \
    "$cursor_home" \
    CURSOR_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    bash "$HOOK_UNDER_TEST"

assert_command_output \
    "SessionStart with SUPERPOWERS_CAPABILITIES=native-worktree injects ensure-worktree" \
    "cursor" \
    "WORKFLOW_MAP"$'\037'"\"to\": \"ensure-worktree\""$'\037'"\"capabilities\": [\"session-inject\", \"native-worktree\"]" \
    "\"native-canvas\"" \
    "$cursor_home" \
    CURSOR_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    SUPERPOWERS_CAPABILITIES=native-worktree \
    bash "$HOOK_UNDER_TEST"

assert_command_output \
    "SessionStart with SUPERPOWERS_CAPABILITIES=native-canvas remaps visual-surface" \
    "cursor" \
    "WORKFLOW_MAP"$'\037'"\"capabilities\": [\"session-inject\", \"native-canvas\"]"$'\037'"select-visual-surface" \
    "\"to\": \"ensure-worktree\"" \
    "$cursor_home" \
    CURSOR_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    SUPERPOWERS_CAPABILITIES=native-canvas \
    bash "$HOOK_UNDER_TEST"

assert_command_output \
    "SessionStart with SUPERPOWERS_CAPABILITIES=exec-hook injects HOST_EXEC" \
    "cursor" \
    "WORKFLOW_MAP"$'\037'"HOST_EXEC"$'\037'"hooks/workflow-exec"$'\037'"--queue"$'\037'"pending-handoff"$'\037'"\"capabilities\": [\"session-inject\", \"exec-hook\"]"$'\037'"do not invent argv" \
    "\"to\": \"ensure-worktree\"" \
    "$cursor_home" \
    CURSOR_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    SUPERPOWERS_CAPABILITIES=exec-hook \
    bash "$HOOK_UNDER_TEST"

bad_proj="$TEST_ROOT/bad-workflow-proj"
mkdir -p "$bad_proj/.superpowers"
echo 'version: "nope"' > "$bad_proj/.superpowers/workflow.yaml"
bad_proj_home="$(make_home bad-workflow-proj)"
if output="$(cd "$bad_proj" && env -i PATH="${PATH:-}" HOME="$bad_proj_home" CURSOR_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$HOOK_UNDER_TEST" 2>&1)"; then
    if printf '%s' "$output" | \
        EXPECT_CONTAINS="WORKFLOW_CONFIG_WARNING"$'\037'"workflow overlay invalid or resolve failed; using bundled defaults only."$'\037'"WORKFLOW_MAP"$'\037'"RESOLVED_JSON"$'\037'"approved-architectural"$'\037'"EXTREMELY_IMPORTANT"$'\037'"using-superpowers" \
        node -e '
const fs = require("fs");
const input = fs.readFileSync(0, "utf8");
let payload;
try {
  payload = JSON.parse(input);
} catch (error) {
  console.error(`invalid JSON: ${error.message}`);
  process.exit(1);
}
const context = payload.additional_context;
if (typeof context !== "string" || context.trim() === "") {
  console.error("injected context was empty");
  process.exit(1);
}
const expected = (process.env.EXPECT_CONTAINS || "").split("\u001f").filter(Boolean);
for (const text of expected) {
  if (!context.includes(text)) {
    console.error(`context did not contain expected text: ${text}`);
    process.exit(1);
  }
}
'; then
        pass "invalid project workflow falls back to bundled map with warning"
    else
        fail "invalid project workflow falls back to bundled map with warning"
        echo "    output:"
        echo "$output" | sed 's/^/      /'
    fi
else
    fail "invalid project workflow falls back to bundled map with warning"
    echo "    hook exited non-zero"
    echo "$output" | sed 's/^/      /'
fi

echo "SessionStart total resolve failure warning"

broken_plugin="$TEST_ROOT/broken-plugin"
mkdir -p "$broken_plugin/hooks" \
    "$broken_plugin/scripts/lib" \
    "$broken_plugin/skills/using-superpowers" \
    "$broken_plugin/workflows"
cp "$REPO_ROOT/hooks/session-start" "$broken_plugin/hooks/session-start"
cp "$REPO_ROOT/scripts/resolve-workflow" "$broken_plugin/scripts/resolve-workflow"
cp "$REPO_ROOT/scripts/lib/"*.py "$broken_plugin/scripts/lib/"
printf '%s\n' '# stub using-superpowers' > "$broken_plugin/skills/using-superpowers/SKILL.md"
printf '%s\n' 'version: "broken-bundled"' > "$broken_plugin/workflows/default.yaml"
broken_home="$(make_home broken-bundled)"
if output="$(cd "$TEST_ROOT" && env -i PATH="${PATH:-}" HOME="$broken_home" CURSOR_PLUGIN_ROOT="$broken_plugin" CLAUDE_PLUGIN_ROOT="$broken_plugin" bash "$broken_plugin/hooks/session-start" 2>&1)"; then
    if printf '%s' "$output" | \
        EXPECT_CONTAINS="WORKFLOW_CONFIG_WARNING"$'\037'"workflow resolve failed (including bundled defaults); no WORKFLOW_MAP available"$'\037'"EXTREMELY_IMPORTANT" \
        EXPECT_NOT_CONTAINS="using bundled defaults only"$'\037'"RESOLVED_JSON" \
        node -e '
const fs = require("fs");
const input = fs.readFileSync(0, "utf8");
let payload;
try {
  payload = JSON.parse(input);
} catch (error) {
  console.error(`invalid JSON: ${error.message}`);
  process.exit(1);
}
const context = payload.additional_context;
if (typeof context !== "string" || context.trim() === "") {
  console.error("injected context was empty");
  process.exit(1);
}
const expected = (process.env.EXPECT_CONTAINS || "").split("\u001f").filter(Boolean);
for (const text of expected) {
  if (!context.includes(text)) {
    console.error(`context did not contain expected text: ${text}`);
    process.exit(1);
  }
}
const forbidden = (process.env.EXPECT_NOT_CONTAINS || "").split("\u001f").filter(Boolean);
for (const text of forbidden) {
  if (context.includes(text)) {
    console.error(`context unexpectedly contained: ${text}`);
    process.exit(1);
  }
}
'; then
        pass "total resolve failure warns without claiming bundled map"
    else
        fail "total resolve failure warns without claiming bundled map"
        echo "    output:"
        echo "$output" | sed 's/^/      /'
    fi
else
    fail "total resolve failure warns without claiming bundled map"
    echo "    hook exited non-zero"
    echo "$output" | sed 's/^/      /'
fi

echo "SessionStart persists real session_id to CLAUDE_ENV_FILE"

persist_home="$(make_home persist-session-id)"
persist_env="$TEST_ROOT/claude-session.env"
rm -f "$persist_env"
if output="$(cd "$TEST_ROOT" && env -i PATH="${PATH:-}" HOME="$persist_home" \
  CURSOR_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
  CLAUDE_ENV_FILE="$persist_env" \
  bash "$HOOK_UNDER_TEST" 2>&1 <<'STDIN'
{"session_id":"sess-persist-1","hook_event_name":"SessionStart"}
STDIN
)"; then
    if [[ -f "$persist_env" ]] && grep -qx 'CLAUDE_SESSION_ID=sess-persist-1' "$persist_env"; then
        pass "SessionStart persists real session_id to CLAUDE_ENV_FILE"
    else
        fail "SessionStart persists real session_id to CLAUDE_ENV_FILE"
        echo "    env file: $(cat "$persist_env" 2>/dev/null || echo missing)"
        echo "$output" | sed 's/^/      /'
    fi
else
    fail "SessionStart persists real session_id to CLAUDE_ENV_FILE"
    echo "    hook exited non-zero"
    echo "$output" | sed 's/^/      /'
fi

if [[ "$FAILURES" -gt 0 ]]; then
    echo "STATUS: FAILED ($FAILURES failure(s))"
    exit 1
fi

echo "STATUS: PASSED"
