#!/usr/bin/env bash
# Tests for scripts/migrate-to-supersuit:
# - rewrites the skill-namespace prefix superpowers: -> supersuit:
# - leaves do-not-touch cases alone
# - dry-run does not write
# - moves overlay/scratch dirs .superpowers/ -> .supersuit/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT_UNDER_TEST="$REPO_ROOT/scripts/migrate-to-supersuit"

FAILURES=0
TEST_ROOT="$(mktemp -d)"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

pass() { echo "  [PASS] $1"; }
fail() {
  echo "  [FAIL] $1"
  FAILURES=$((FAILURES + 1))
}

assert_file_contains() {
  local file="$1"
  local needle="$2"
  local description="$3"
  if grep -Fq -- "$needle" "$file"; then
    pass "$description"
  else
    fail "$description"
    echo "    expected to find: $needle"
    echo "    in: $file"
    sed 's/^/      /' "$file"
  fi
}

assert_file_not_contains() {
  local file="$1"
  local needle="$2"
  local description="$3"
  if grep -Fq -- "$needle" "$file"; then
    fail "$description"
    echo "    did not expect to find: $needle"
    echo "    in: $file"
    sed 's/^/      /' "$file"
  else
    pass "$description"
  fi
}

write_sample_project() {
  local root="$1"
  mkdir -p "$root/.superpowers/sdd/plan-a" \
    "$root/.superpowers/brainstorm/old-session" \
    "$root/docs" \
    "$root/bin"
  cat >"$root/AGENTS.md" <<'EOF'
Use superpowers:brainstorming before coding.
Then invoke superpowers:using-superpowers if skills stop triggering.
The skill folder is using-superpowers.
Config lives in .superpowers/workflow.yaml and ~/.superpowers/workflow.yaml.
Upstream product: obra/superpowers
Telemetry: SUPERPOWERS_DISABLE_TELEMETRY=1
Do not enable both Superpowers and Supersuit.
EOF
  cat >"$root/.superpowers/workflow.yaml" <<'EOF'
version: 1
skills:
  brainstorming:
    skill: superpowers:brainstorming
EOF
  printf 'ledger\n' >"$root/.superpowers/sdd/plan-a/progress.md"
  printf 'mockup\n' >"$root/.superpowers/brainstorm/old-session/index.html"
  printf 'plain superpowers mention and obra/superpowers link\n' >"$root/docs/notes.md"
  printf 'superpowers:\x00binary' >"$root/bin/blob.bin"
}

echo "=== migrate-to-supersuit ==="

if [[ ! -x "$SCRIPT_UNDER_TEST" && ! -f "$SCRIPT_UNDER_TEST" ]]; then
  fail "scripts/migrate-to-supersuit exists"
  echo "FAILED: $FAILURES"
  exit 1
fi
pass "scripts/migrate-to-supersuit exists"

# --- dry-run (default) does not write ---
dry_proj="$TEST_ROOT/dry"
write_sample_project "$dry_proj"
cp "$dry_proj/AGENTS.md" "$TEST_ROOT/AGENTS.md.before"

if ! "$SCRIPT_UNDER_TEST" -n "$dry_proj" >"$TEST_ROOT/dry.out" 2>"$TEST_ROOT/dry.err"; then
  fail "dry-run exits 0"
  sed 's/^/    /' "$TEST_ROOT/dry.err"
else
  pass "dry-run exits 0"
fi

if cmp -s "$TEST_ROOT/AGENTS.md.before" "$dry_proj/AGENTS.md"; then
  pass "dry-run does not rewrite text files"
else
  fail "dry-run does not rewrite text files"
fi

if [[ -d "$dry_proj/.superpowers" && ! -d "$dry_proj/.supersuit" ]]; then
  pass "dry-run does not move .superpowers/"
else
  fail "dry-run does not move .superpowers/"
fi

if grep -Eqi 'dry|would|rewrite|move' "$TEST_ROOT/dry.out"; then
  pass "dry-run reports planned work"
else
  fail "dry-run reports planned work"
  sed 's/^/    /' "$TEST_ROOT/dry.out"
fi

# default (no --write) is also dry-run
default_proj="$TEST_ROOT/default-dry"
write_sample_project "$default_proj"
"$SCRIPT_UNDER_TEST" "$default_proj" >"$TEST_ROOT/default-dry.out"
if [[ -d "$default_proj/.superpowers" && ! -d "$default_proj/.supersuit" ]] &&
  grep -Fq 'superpowers:brainstorming' "$default_proj/AGENTS.md"; then
  pass "default invocation is dry-run"
else
  fail "default invocation is dry-run"
fi

# --- --write rewrites prefix and moves dirs ---
write_proj="$TEST_ROOT/write"
write_sample_project "$write_proj"

if ! "$SCRIPT_UNDER_TEST" --write "$write_proj" >"$TEST_ROOT/write.out" 2>"$TEST_ROOT/write.err"; then
  fail "--write exits 0"
  sed 's/^/    /' "$TEST_ROOT/write.err"
else
  pass "--write exits 0"
fi

assert_file_contains "$write_proj/AGENTS.md" "supersuit:brainstorming" "rewrites superpowers:brainstorming"
assert_file_contains "$write_proj/AGENTS.md" "supersuit:using-superpowers" "rewrites invocation prefix on using-superpowers"
assert_file_contains "$write_proj/AGENTS.md" "using-superpowers" "keeps skill folder name using-superpowers"
assert_file_contains "$write_proj/AGENTS.md" ".superpowers/workflow.yaml" "does not rewrite .superpowers/ path segments"
assert_file_contains "$write_proj/AGENTS.md" "~/.superpowers/workflow.yaml" "does not rewrite ~/.superpowers/ path segments"
assert_file_contains "$write_proj/AGENTS.md" "obra/superpowers" "does not rewrite obra/superpowers"
assert_file_contains "$write_proj/AGENTS.md" "SUPERPOWERS_DISABLE_TELEMETRY=1" "does not rewrite SUPERPOWERS_ env vars"
assert_file_not_contains "$write_proj/AGENTS.md" "superpowers:brainstorming" "removes old invocation prefix"
assert_file_contains "$write_proj/docs/notes.md" "obra/superpowers" "leaves product references in other files"

if [[ -d "$write_proj/.supersuit/sdd/plan-a" && -f "$write_proj/.supersuit/sdd/plan-a/progress.md" ]]; then
  pass "moves project .superpowers/ scratch into .supersuit/"
else
  fail "moves project .superpowers/ scratch into .supersuit/"
fi

if [[ -f "$write_proj/.supersuit/workflow.yaml" ]]; then
  pass "moves project overlay to .supersuit/workflow.yaml"
else
  fail "moves project overlay to .supersuit/workflow.yaml"
fi

if [[ -d "$write_proj/.superpowers" ]]; then
  fail "removes project .superpowers/ after a clean move"
else
  pass "removes project .superpowers/ after a clean move"
fi

assert_file_contains "$write_proj/.supersuit/workflow.yaml" "supersuit:brainstorming" "rewrites invocations inside moved overlay"

if grep -Fq $'superpowers:\x00binary' "$write_proj/bin/blob.bin"; then
  pass "does not rewrite binary files"
else
  fail "does not rewrite binary files"
fi

# --- --user migrates ~/.superpowers when opted in ---
user_home="$TEST_ROOT/home"
mkdir -p "$user_home/.superpowers"
printf 'version: 1\n# use superpowers:writing-plans\n' >"$user_home/.superpowers/workflow.yaml"
user_proj="$TEST_ROOT/user-proj"
mkdir -p "$user_proj"

if ! "$SCRIPT_UNDER_TEST" --write --user --user-home "$user_home" "$user_proj" \
  >"$TEST_ROOT/user.out" 2>"$TEST_ROOT/user.err"; then
  fail "--user write exits 0"
  sed 's/^/    /' "$TEST_ROOT/user.err"
else
  pass "--user write exits 0"
fi

if [[ -f "$user_home/.supersuit/workflow.yaml" && ! -d "$user_home/.superpowers" ]]; then
  pass "moves ~/.superpowers/ to ~/.supersuit/ when --user is set"
else
  fail "moves ~/.superpowers/ to ~/.supersuit/ when --user is set"
fi
assert_file_contains "$user_home/.supersuit/workflow.yaml" "supersuit:writing-plans" "rewrites invocations in user overlay"

# without --user, home dir is left alone even if it exists
leave_home="$TEST_ROOT/leave-home"
mkdir -p "$leave_home/.superpowers"
printf 'version: 1\n' >"$leave_home/.superpowers/workflow.yaml"
leave_proj="$TEST_ROOT/leave-proj"
mkdir -p "$leave_proj"
"$SCRIPT_UNDER_TEST" --write --user-home "$leave_home" "$leave_proj" >/dev/null
if [[ -d "$leave_home/.superpowers" && ! -d "$leave_home/.supersuit" ]]; then
  pass "does not move ~/.superpowers/ unless --user is set"
else
  fail "does not move ~/.superpowers/ unless --user is set"
fi

# --- dest exists: do not clobber ---
both="$TEST_ROOT/both"
mkdir -p "$both/.superpowers" "$both/.supersuit"
printf 'legacy: superpowers:brainstorming\n' >"$both/.superpowers/workflow.yaml"
printf 'canonical: keep\n' >"$both/.supersuit/workflow.yaml"
"$SCRIPT_UNDER_TEST" --write "$both" >/dev/null
if grep -Fq 'canonical: keep' "$both/.supersuit/workflow.yaml"; then
  pass "does not clobber an existing .supersuit/ overlay"
else
  fail "does not clobber an existing .supersuit/ overlay"
fi
if [[ -d "$both/.superpowers" ]]; then
  pass "leaves .superpowers/ in place when .supersuit/ already exists"
else
  fail "leaves .superpowers/ in place when .supersuit/ already exists"
fi

if [[ "$FAILURES" -gt 0 ]]; then
  echo "FAILED: $FAILURES"
  exit 1
fi
echo "All migrate-to-supersuit tests passed"
exit 0
