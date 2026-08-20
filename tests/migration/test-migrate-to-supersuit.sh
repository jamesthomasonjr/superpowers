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

# --- --user + project root == user_home: one move, exit 0 ---
overlap_home="$TEST_ROOT/overlap-home"
mkdir -p "$overlap_home/.superpowers"
printf 'version: 1\n# use superpowers:writing-plans\n' >"$overlap_home/.superpowers/workflow.yaml"
set +e
"$SCRIPT_UNDER_TEST" --write --user --user-home "$overlap_home" "$overlap_home" \
  >"$TEST_ROOT/overlap.out" 2>"$TEST_ROOT/overlap.err"
overlap_status=$?
set -e
if [[ "$overlap_status" -eq 0 ]]; then
  pass "--write --user with project root == user_home exits 0"
else
  fail "--write --user with project root == user_home exits 0"
  echo "    exit: $overlap_status"
  sed 's/^/    /' "$TEST_ROOT/overlap.err"
fi
if [[ -f "$overlap_home/.supersuit/workflow.yaml" && ! -d "$overlap_home/.superpowers" ]]; then
  pass "overlap case performs a single home rename"
else
  fail "overlap case performs a single home rename"
fi
overlap_moves="$(grep -c '^  move ' "$TEST_ROOT/overlap.out" || true)"
if [[ "$overlap_moves" -eq 1 ]]; then
  pass "overlap case reports one move"
else
  fail "overlap case reports one move"
  echo "    move lines: $overlap_moves"
  sed 's/^/    /' "$TEST_ROOT/overlap.out"
fi

# --- distinct project root + --user still moves both ---
distinct_home="$TEST_ROOT/distinct-home"
distinct_proj="$TEST_ROOT/distinct-proj"
mkdir -p "$distinct_home/.superpowers" "$distinct_proj/.superpowers"
printf 'home-overlay\n' >"$distinct_home/.superpowers/workflow.yaml"
printf 'proj-overlay\n' >"$distinct_proj/.superpowers/workflow.yaml"
if ! "$SCRIPT_UNDER_TEST" --write --user --user-home "$distinct_home" "$distinct_proj" \
  >"$TEST_ROOT/distinct.out" 2>"$TEST_ROOT/distinct.err"; then
  fail "distinct project + --user exits 0"
  sed 's/^/    /' "$TEST_ROOT/distinct.err"
else
  pass "distinct project + --user exits 0"
fi
if [[ -f "$distinct_home/.supersuit/workflow.yaml" && ! -d "$distinct_home/.superpowers" &&
      -f "$distinct_proj/.supersuit/workflow.yaml" && ! -d "$distinct_proj/.superpowers" ]]; then
  pass "distinct project + --user moves both dirs"
else
  fail "distinct project + --user moves both dirs"
fi
distinct_moves="$(grep -c '^  move ' "$TEST_ROOT/distinct.out" || true)"
if [[ "$distinct_moves" -eq 2 ]]; then
  pass "distinct project + --user reports two moves"
else
  fail "distinct project + --user reports two moves"
  echo "    move lines: $distinct_moves"
  sed 's/^/    /' "$TEST_ROOT/distinct.out"
fi

# --- file symlink to an outside target is not rewritten ---
outside_target="$TEST_ROOT/outside-shared.md"
printf 'superpowers:brainstorming\n' >"$outside_target"
symlink_proj="$TEST_ROOT/symlink-proj"
mkdir -p "$symlink_proj"
ln -s "$outside_target" "$symlink_proj/AGENTS.md"
printf 'regular superpowers:writing-plans\n' >"$symlink_proj/NOTES.md"
if ! "$SCRIPT_UNDER_TEST" --write "$symlink_proj" \
  >"$TEST_ROOT/symlink.out" 2>"$TEST_ROOT/symlink.err"; then
  fail "symlink tree --write exits 0"
  sed 's/^/    /' "$TEST_ROOT/symlink.err"
else
  pass "symlink tree --write exits 0"
fi
if [[ -L "$symlink_proj/AGENTS.md" ]]; then
  pass "leaves AGENTS.md as a symlink"
else
  fail "leaves AGENTS.md as a symlink"
fi
assert_file_contains "$outside_target" "superpowers:brainstorming" \
  "does not rewrite a symlink target outside the tree"
assert_file_not_contains "$outside_target" "supersuit:brainstorming" \
  "outside symlink target keeps the old prefix"
assert_file_contains "$symlink_proj/NOTES.md" "supersuit:writing-plans" \
  "still rewrites regular files in the same tree"

# --- non-regular file (FIFO) is not opened / does not hang ---
fifo_proj="$TEST_ROOT/fifo-proj"
mkdir -p "$fifo_proj"
mkfifo "$fifo_proj/pipe"
printf 'superpowers:brainstorming\n' >"$fifo_proj/README.md"
if command -v timeout >/dev/null 2>&1; then
  set +e
  timeout 5 "$SCRIPT_UNDER_TEST" --write "$fifo_proj" \
    >"$TEST_ROOT/fifo.out" 2>"$TEST_ROOT/fifo.err"
  fifo_status=$?
  set -e
else
  set +e
  "$SCRIPT_UNDER_TEST" --write "$fifo_proj" \
    >"$TEST_ROOT/fifo.out" 2>"$TEST_ROOT/fifo.err"
  fifo_status=$?
  set -e
fi
if [[ "$fifo_status" -eq 0 ]]; then
  pass "FIFO in tree does not hang and exits 0"
else
  fail "FIFO in tree does not hang and exits 0"
  echo "    exit: $fifo_status"
  sed 's/^/    /' "$TEST_ROOT/fifo.err"
fi
assert_file_contains "$fifo_proj/README.md" "supersuit:brainstorming" \
  "rewrites regular files next to a FIFO"
if [[ -p "$fifo_proj/pipe" ]]; then
  pass "leaves the FIFO in place"
else
  fail "leaves the FIFO in place"
fi

# --- binaries-only tree is a no-op dry-run ---
bin_only="$TEST_ROOT/bin-only"
mkdir -p "$bin_only"
printf 'superpowers:\x00png' >"$bin_only/icon.bin"
if ! "$SCRIPT_UNDER_TEST" -n "$bin_only" \
  >"$TEST_ROOT/bin-only.out" 2>"$TEST_ROOT/bin-only.err"; then
  fail "binaries-only dry-run exits 0"
  sed 's/^/    /' "$TEST_ROOT/bin-only.err"
else
  pass "binaries-only dry-run exits 0"
fi
if grep -Fq 'no changes needed' "$TEST_ROOT/bin-only.out"; then
  pass "binaries-only dry-run prints no changes needed"
else
  fail "binaries-only dry-run prints no changes needed"
  sed 's/^/    /' "$TEST_ROOT/bin-only.out"
fi
if grep -Fq 'skip-binary' "$TEST_ROOT/bin-only.out"; then
  fail "binaries-only dry-run does not list skip-binary"
  sed 's/^/    /' "$TEST_ROOT/bin-only.out"
else
  pass "binaries-only dry-run does not list skip-binary"
fi
if grep -Fq 'Re-run with --write' "$TEST_ROOT/bin-only.out"; then
  fail "binaries-only dry-run does not tell the user to --write"
  sed 's/^/    /' "$TEST_ROOT/bin-only.out"
else
  pass "binaries-only dry-run does not tell the user to --write"
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
