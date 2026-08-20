#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SYNC_SCRIPT_SOURCE="$REPO_ROOT/scripts/sync-to-codex-plugin.sh"
BASH_UNDER_TEST="/bin/bash"
PACKAGE_VERSION="1.2.3"
MANIFEST_VERSION="9.8.7"

FAILURES=0
TEST_ROOT=""

pass() {
    echo "  [PASS] $1"
}

fail() {
    echo "  [FAIL] $1"
    FAILURES=$((FAILURES + 1))
}

assert_equals() {
    local actual="$1"
    local expected="$2"
    local description="$3"

    if [[ "$actual" == "$expected" ]]; then
        pass "$description"
    else
        fail "$description"
        echo "    expected: $expected"
        echo "    actual:   $actual"
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local description="$3"

    if printf '%s' "$haystack" | grep -Fq -- "$needle"; then
        pass "$description"
    else
        fail "$description"
        echo "    expected to find: $needle"
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local description="$3"

    if printf '%s' "$haystack" | grep -Fq -- "$needle"; then
        fail "$description"
        echo "    did not expect to find: $needle"
    else
        pass "$description"
    fi
}

assert_matches() {
    local haystack="$1"
    local pattern="$2"
    local description="$3"

    if printf '%s' "$haystack" | grep -Eq -- "$pattern"; then
        pass "$description"
    else
        fail "$description"
        echo "    expected to match: $pattern"
    fi
}

assert_not_matches() {
    local haystack="$1"
    local pattern="$2"
    local description="$3"

    if printf '%s' "$haystack" | grep -Eq -- "$pattern"; then
        fail "$description"
        echo "    did not expect to match: $pattern"
    else
        pass "$description"
    fi
}

assert_path_absent() {
    local path="$1"
    local description="$2"

    if [[ ! -e "$path" ]]; then
        pass "$description"
    else
        fail "$description"
        echo "    did not expect path to exist: $path"
    fi
}

assert_branch_absent() {
    local repo="$1"
    local pattern="$2"
    local description="$3"
    local branches

    branches="$(git -C "$repo" branch --list "$pattern")"

    if [[ -z "$branches" ]]; then
        pass "$description"
    else
        fail "$description"
        echo "    did not expect matching branches:"
        echo "$branches" | sed 's/^/      /'
    fi
}

assert_current_branch() {
    local repo="$1"
    local expected="$2"
    local description="$3"
    local actual

    actual="$(git -C "$repo" branch --show-current)"
    assert_equals "$actual" "$expected" "$description"
}

assert_file_equals() {
    local path="$1"
    local expected="$2"
    local description="$3"
    local actual

    actual="$(cat "$path")"
    assert_equals "$actual" "$expected" "$description"
}

cleanup() {
    if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
        rm -rf "$TEST_ROOT"
    fi
}

configure_git_identity() {
    local repo="$1"

    git -C "$repo" config user.name "Test Bot"
    git -C "$repo" config user.email "test@example.com"
}

init_repo() {
    local repo="$1"

    git init -q -b main "$repo"
    configure_git_identity "$repo"
}

commit_fixture() {
    local repo="$1"
    local message="$2"

    git -C "$repo" commit -q -m "$message"
}

checkout_fixture_branch() {
    local repo="$1"
    local branch="$2"

    git -C "$repo" checkout -q -b "$branch"
}

write_upstream_fixture() {
    local repo="$1"
    local with_pure_ignored="${2:-1}"

    mkdir -p \
        "$repo/.codex-plugin" \
        "$repo/.kimi-plugin" \
        "$repo/.private-journal" \
        "$repo/assets" \
        "$repo/evals/drill" \
        "$repo/hooks" \
        "$repo/scripts" \
        "$repo/skills/example"

    if [[ "$with_pure_ignored" == "1" ]]; then
        mkdir -p "$repo/ignored-cache/tmp"
    fi

    cp "$SYNC_SCRIPT_SOURCE" "$repo/scripts/sync-to-codex-plugin.sh"

    cat > "$repo/package.json" <<EOF
{
  "name": "fixture-upstream",
  "version": "$PACKAGE_VERSION"
}
EOF

    cat > "$repo/.gitignore" <<'EOF'
.private-journal/
EOF

    cat > "$repo/.gitmodules" <<'EOF'
[submodule "evals"]
	path = evals
	url = git@example.com:example/evals.git
EOF

    cat > "$repo/.pre-commit-config.yaml" <<'EOF'
repos:
  - repo: local
    hooks:
      - id: evals-check
        name: evals check
        entry: echo evals
        language: system
        files: ^evals/
EOF

    if [[ "$with_pure_ignored" == "1" ]]; then
        cat >> "$repo/.gitignore" <<'EOF'
ignored-cache/
EOF
    fi

    cat > "$repo/.codex-plugin/plugin.json" <<EOF
{
  "name": "supersuit",
  "version": "$MANIFEST_VERSION"
}
EOF

    cat > "$repo/.kimi-plugin/plugin.json" <<EOF
{
  "name": "supersuit",
  "version": "$MANIFEST_VERSION"
}
EOF

    cat > "$repo/assets/superpowers-small.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1"></svg>
EOF

    printf 'png fixture\n' > "$repo/assets/app-icon.png"
    printf 'eval harness fixture\n' > "$repo/evals/drill/README.md"

    cat > "$repo/hooks/hooks-codex.json" <<'EOF'
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume|clear",
        "hooks": [
          {
            "type": "command",
            "command": "\"${PLUGIN_ROOT}/hooks/run-hook.cmd\" session-start-codex",
            "async": false
          }
        ]
      }
    ]
  }
}
EOF

    cat > "$repo/hooks/session-start" <<'EOF'
#!/usr/bin/env sh
echo "session-start fixture"
EOF
    cat > "$repo/hooks/session-start-codex" <<'EOF'
#!/usr/bin/env sh
echo "session-start-codex fixture"
EOF

    cat > "$repo/hooks/run-hook.cmd" <<'EOF'
@echo off
echo run-hook fixture
EOF
    chmod +x "$repo/hooks/session-start" "$repo/hooks/session-start-codex" "$repo/hooks/run-hook.cmd"

    cat > "$repo/skills/example/SKILL.md" <<'EOF'
# Example Skill

Fixture content.
EOF

    printf 'tracked keep\n' > "$repo/.private-journal/keep.txt"
    printf 'ignored leak\n' > "$repo/.private-journal/leak.txt"
    if [[ "$with_pure_ignored" == "1" ]]; then
        printf 'ignored cache state\n' > "$repo/ignored-cache/tmp/state.json"
    fi

    git -C "$repo" add \
        .codex-plugin/plugin.json \
        .kimi-plugin/plugin.json \
        .gitignore \
        .gitmodules \
        .pre-commit-config.yaml \
        assets/app-icon.png \
        assets/superpowers-small.svg \
        evals/drill/README.md \
        hooks/hooks-codex.json \
        hooks/run-hook.cmd \
        hooks/session-start \
        hooks/session-start-codex \
        package.json \
        scripts/sync-to-codex-plugin.sh \
        skills/example/SKILL.md
    git -C "$repo" add -f .private-journal/keep.txt

    commit_fixture "$repo" "Initial upstream fixture"
}

write_destination_fixture() {
    local repo="$1"

    mkdir -p "$repo/plugins/supersuit/skills/example"
    printf 'fixture keep\n' > "$repo/plugins/supersuit/.fixture-keep"
    cat > "$repo/plugins/supersuit/skills/example/SKILL.md" <<'EOF'
# Example Skill

Fixture content.
EOF
    git -C "$repo" add plugins/supersuit/.fixture-keep
    git -C "$repo" add plugins/supersuit/skills/example/SKILL.md

    commit_fixture "$repo" "Initial destination fixture"
}

add_openai_agent_metadata_fixture() {
    local repo="$1"

    mkdir -p "$repo/plugins/supersuit/skills/example/agents"

    cat > "$repo/plugins/supersuit/skills/example/agents/openai.yaml" <<'EOF'
interface:
  display_name: "Example"
  short_description: "Destination-owned OpenAI metadata"
EOF

    git -C "$repo" add plugins/supersuit/skills/example/agents/openai.yaml

    commit_fixture "$repo" "Add OpenAI agent metadata fixture"
}

dirty_tracked_destination_skill() {
    local repo="$1"

    cat > "$repo/plugins/supersuit/skills/example/SKILL.md" <<'EOF'
# Example Skill

Locally modified fixture content.
EOF
}

write_synced_destination_fixture() {
    local repo="$1"

    mkdir -p \
        "$repo/plugins/supersuit/.codex-plugin" \
        "$repo/plugins/supersuit/.private-journal" \
        "$repo/plugins/supersuit/assets" \
        "$repo/plugins/supersuit/hooks" \
        "$repo/plugins/supersuit/skills/example/agents" \
        "$repo/plugins/supersuit/skills/example"

    cat > "$repo/plugins/supersuit/.codex-plugin/plugin.json" <<EOF
{
  "name": "supersuit",
  "version": "$MANIFEST_VERSION"
}
EOF

    cat > "$repo/plugins/supersuit/assets/superpowers-small.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1"></svg>
EOF

    printf 'png fixture\n' > "$repo/plugins/supersuit/assets/app-icon.png"

    cat > "$repo/plugins/supersuit/hooks/hooks-codex.json" <<'EOF'
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume|clear",
        "hooks": [
          {
            "type": "command",
            "command": "\"${PLUGIN_ROOT}/hooks/run-hook.cmd\" session-start-codex",
            "async": false
          }
        ]
      }
    ]
  }
}
EOF

    cat > "$repo/plugins/supersuit/hooks/session-start" <<'EOF'
#!/usr/bin/env sh
echo "session-start fixture"
EOF
    cat > "$repo/plugins/supersuit/hooks/session-start-codex" <<'EOF'
#!/usr/bin/env sh
echo "session-start-codex fixture"
EOF

    cat > "$repo/plugins/supersuit/hooks/run-hook.cmd" <<'EOF'
@echo off
echo run-hook fixture
EOF
    chmod +x "$repo/plugins/supersuit/hooks/session-start" "$repo/plugins/supersuit/hooks/session-start-codex" "$repo/plugins/supersuit/hooks/run-hook.cmd"

    cat > "$repo/plugins/supersuit/skills/example/SKILL.md" <<'EOF'
# Example Skill

Fixture content.
EOF

    cat > "$repo/plugins/supersuit/skills/example/agents/openai.yaml" <<'EOF'
interface:
  display_name: "Example"
  short_description: "Destination-owned OpenAI metadata"
EOF

    printf 'tracked keep\n' > "$repo/plugins/supersuit/.private-journal/keep.txt"

    git -C "$repo" add \
        plugins/supersuit/.codex-plugin/plugin.json \
        plugins/supersuit/assets/app-icon.png \
        plugins/supersuit/assets/superpowers-small.svg \
        plugins/supersuit/hooks/hooks-codex.json \
        plugins/supersuit/hooks/run-hook.cmd \
        plugins/supersuit/hooks/session-start \
        plugins/supersuit/hooks/session-start-codex \
        plugins/supersuit/skills/example/agents/openai.yaml \
        plugins/supersuit/skills/example/SKILL.md \
        plugins/supersuit/.private-journal/keep.txt

    commit_fixture "$repo" "Initial synced destination fixture"
}

write_stale_ignored_destination_fixture() {
    local repo="$1"

    mkdir -p \
        "$repo/plugins/supersuit/.kimi-plugin" \
        "$repo/plugins/supersuit/.private-journal"
    printf 'fixture keep\n' > "$repo/plugins/supersuit/.fixture-keep"
    printf '{"name":"stale-kimi"}\n' > "$repo/plugins/supersuit/.kimi-plugin/plugin.json"
    printf 'stale ignored leak\n' > "$repo/plugins/supersuit/.private-journal/leak.txt"
    git -C "$repo" add \
        plugins/supersuit/.fixture-keep \
        plugins/supersuit/.kimi-plugin/plugin.json

    commit_fixture "$repo" "Initial stale ignored destination fixture"
}

write_fake_gh() {
    local bin_dir="$1"

    mkdir -p "$bin_dir"

    cat > "$bin_dir/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
    exit 0
fi

echo "unexpected gh invocation: $*" >&2
exit 1
EOF

    chmod +x "$bin_dir/gh"
}

run_preview() {
    local upstream="$1"
    local dest="$2"
    local fake_bin="$3"

    PATH="$fake_bin:$PATH" "$BASH_UNDER_TEST" "$upstream/scripts/sync-to-codex-plugin.sh" -n --local "$dest" 2>&1
}

run_bootstrap_preview() {
    local upstream="$1"
    local dest="$2"
    local fake_bin="$3"

    PATH="$fake_bin:$PATH" "$BASH_UNDER_TEST" "$upstream/scripts/sync-to-codex-plugin.sh" -n --bootstrap --local "$dest" 2>&1
}

run_preview_without_manifest() {
    local upstream="$1"
    local dest="$2"
    local fake_bin="$3"

    rm -f "$upstream/.codex-plugin/plugin.json"
    PATH="$fake_bin:$PATH" "$BASH_UNDER_TEST" "$upstream/scripts/sync-to-codex-plugin.sh" -n --local "$dest" 2>&1
}

run_preview_with_stale_ignored_destination() {
    local upstream="$1"
    local dest="$2"
    local fake_bin="$3"

    PATH="$fake_bin:$PATH" "$BASH_UNDER_TEST" "$upstream/scripts/sync-to-codex-plugin.sh" -n --local "$dest" 2>&1
}

run_apply() {
    local upstream="$1"
    local dest="$2"
    local fake_bin="$3"

    PATH="$fake_bin:$PATH" "$BASH_UNDER_TEST" "$upstream/scripts/sync-to-codex-plugin.sh" -y --local "$dest" 2>&1
}

run_help() {
    local upstream="$1"
    local fake_bin="$2"

    PATH="$fake_bin:$PATH" "$BASH_UNDER_TEST" "$upstream/scripts/sync-to-codex-plugin.sh" --help 2>&1
}

write_logging_fake_gh() {
    local bin_dir="$1"
    local log="$2"

    mkdir -p "$bin_dir"

    cat > "$bin_dir/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "\$*" >> "$log"

if [[ "\${1:-}" == "auth" && "\${2:-}" == "status" ]]; then
    exit 0
fi

if [[ "\${1:-}" == "repo" && "\${2:-}" == "view" ]]; then
    exit 1
fi

exit 1
EOF

    chmod +x "$bin_dir/gh"
}

run_non_local_preview() {
    local upstream="$1"
    local fake_bin="$2"
    shift 2

    env -u CODEX_PLUGINS_FORK PATH="$fake_bin:$PATH" "$BASH_UNDER_TEST" \
        "$upstream/scripts/sync-to-codex-plugin.sh" -n "$@" 2>&1
}

run_non_local_preview_with_fork_env() {
    local upstream="$1"
    local fake_bin="$2"
    local fork="$3"

    env CODEX_PLUGINS_FORK="$fork" PATH="$fake_bin:$PATH" "$BASH_UNDER_TEST" \
        "$upstream/scripts/sync-to-codex-plugin.sh" -n 2>&1
}

write_bootstrap_destination_fixture() {
    local repo="$1"

    printf 'bootstrap fixture\n' > "$repo/README.md"
    git -C "$repo" add README.md

    commit_fixture "$repo" "Initial bootstrap destination fixture"
}

main() {
    local upstream
    local mixed_only_upstream
    local dest
    local dest_branch
    local mixed_only_dest
    local stale_dest
    local dirty_apply_dest
    local dirty_apply_dest_branch
    local noop_apply_dest
    local noop_apply_dest_branch
    local fake_bin
    local bootstrap_dest
    local bootstrap_dest_branch
    local preview_status
    local preview_output
    local preview_section
    local bootstrap_status
    local bootstrap_output
    local missing_manifest_status
    local missing_manifest_output
    local mixed_only_status
    local mixed_only_output
    local stale_preview_status
    local stale_preview_output
    local stale_preview_section
    local dirty_apply_status
    local dirty_apply_output
    local noop_apply_status
    local noop_apply_output
    local help_output
    local script_source
    local dirty_skill_path
    local noop_openai_metadata_path
    local dest_fake_bin
    local dest_gh_log
    local missing_fork_status
    local missing_fork_output
    local missing_fork_log
    local uncloneable_status
    local uncloneable_output
    local uncloneable_log
    local uncloneable_fork

    echo "=== Test: sync-to-codex-plugin dry-run regression ==="

    TEST_ROOT="$(mktemp -d)"
    trap cleanup EXIT

    upstream="$TEST_ROOT/upstream"
    mixed_only_upstream="$TEST_ROOT/mixed-only-upstream"
    dest="$TEST_ROOT/destination"
    mixed_only_dest="$TEST_ROOT/mixed-only-destination"
    stale_dest="$TEST_ROOT/stale-destination"
    dirty_apply_dest="$TEST_ROOT/dirty-apply-destination"
    dirty_apply_dest_branch="fixture/dirty-apply-target"
    noop_apply_dest="$TEST_ROOT/noop-apply-destination"
    noop_apply_dest_branch="fixture/noop-apply-target"
    bootstrap_dest="$TEST_ROOT/bootstrap-destination"
    dest_branch="fixture/preview-target"
    bootstrap_dest_branch="fixture/bootstrap-preview-target"
    fake_bin="$TEST_ROOT/bin"

    init_repo "$upstream"
    write_upstream_fixture "$upstream"

    init_repo "$mixed_only_upstream"
    write_upstream_fixture "$mixed_only_upstream" 0

    init_repo "$dest"
    write_destination_fixture "$dest"
    add_openai_agent_metadata_fixture "$dest"
    checkout_fixture_branch "$dest" "$dest_branch"
    dirty_tracked_destination_skill "$dest"

    init_repo "$mixed_only_dest"
    write_destination_fixture "$mixed_only_dest"

    init_repo "$stale_dest"
    write_stale_ignored_destination_fixture "$stale_dest"

    init_repo "$dirty_apply_dest"
    write_synced_destination_fixture "$dirty_apply_dest"
    checkout_fixture_branch "$dirty_apply_dest" "$dirty_apply_dest_branch"
    dirty_tracked_destination_skill "$dirty_apply_dest"

    init_repo "$noop_apply_dest"
    write_synced_destination_fixture "$noop_apply_dest"
    checkout_fixture_branch "$noop_apply_dest" "$noop_apply_dest_branch"

    init_repo "$bootstrap_dest"
    write_bootstrap_destination_fixture "$bootstrap_dest"
    checkout_fixture_branch "$bootstrap_dest" "$bootstrap_dest_branch"

    write_fake_gh "$fake_bin"

    # This regression test is about dry-run content, so capture the preview
    # output even if the current script exits nonzero in --local mode.
    set +e
    preview_output="$(run_preview "$upstream" "$dest" "$fake_bin")"
    preview_status=$?
    bootstrap_output="$(run_bootstrap_preview "$upstream" "$bootstrap_dest" "$fake_bin")"
    bootstrap_status=$?
    mixed_only_output="$(run_preview "$mixed_only_upstream" "$mixed_only_dest" "$fake_bin")"
    mixed_only_status=$?
    stale_preview_output="$(run_preview_with_stale_ignored_destination "$upstream" "$stale_dest" "$fake_bin")"
    stale_preview_status=$?
    dirty_apply_output="$(run_apply "$upstream" "$dirty_apply_dest" "$fake_bin")"
    dirty_apply_status=$?
    noop_apply_output="$(run_apply "$upstream" "$noop_apply_dest" "$fake_bin")"
    noop_apply_status=$?
    dest_fake_bin="$TEST_ROOT/dest-bin"
    dest_gh_log="$TEST_ROOT/dest-gh.log"
    uncloneable_fork="missing-org/does-not-exist-codex-plugins"
    : > "$dest_gh_log"
    write_logging_fake_gh "$dest_fake_bin" "$dest_gh_log"
    missing_fork_output="$(run_non_local_preview "$upstream" "$dest_fake_bin")"
    missing_fork_status=$?
    missing_fork_log="$(cat "$dest_gh_log")"
    : > "$dest_gh_log"
    uncloneable_output="$(run_non_local_preview_with_fork_env "$upstream" "$dest_fake_bin" "$uncloneable_fork")"
    uncloneable_status=$?
    uncloneable_log="$(cat "$dest_gh_log")"
    missing_manifest_output="$(run_preview_without_manifest "$upstream" "$dest" "$fake_bin")"
    missing_manifest_status=$?
    set -e
    help_output="$(run_help "$upstream" "$fake_bin")"
    script_source="$(cat "$upstream/scripts/sync-to-codex-plugin.sh")"
    preview_section="$(printf '%s\n' "$preview_output" | sed -n '/^=== Preview (rsync --dry-run) ===$/,/^=== End preview ===$/p')"
    stale_preview_section="$(printf '%s\n' "$stale_preview_output" | sed -n '/^=== Preview (rsync --dry-run) ===$/,/^=== End preview ===$/p')"
    dirty_skill_path="$dirty_apply_dest/plugins/supersuit/skills/example/SKILL.md"
    noop_openai_metadata_path="$noop_apply_dest/plugins/supersuit/skills/example/agents/openai.yaml"

    echo ""
    echo "Preview assertions..."
    assert_equals "$preview_status" "0" "Preview exits successfully"
    assert_contains "$preview_output" "Version:  $MANIFEST_VERSION" "Preview uses manifest version"
    assert_not_contains "$preview_output" "Version:  $PACKAGE_VERSION" "Preview does not use package.json version"
    assert_contains "$preview_section" ".codex-plugin/plugin.json" "Preview includes manifest path"
    assert_not_contains "$preview_section" ".kimi-plugin/plugin.json" "Preview excludes Kimi manifest from Codex sync"
    assert_contains "$preview_section" "assets/superpowers-small.svg" "Preview includes SVG asset"
    assert_contains "$preview_section" "assets/app-icon.png" "Preview includes PNG asset"
    assert_contains "$preview_section" "hooks/hooks-codex.json" "Preview includes Codex hook manifest"
    assert_contains "$preview_section" "hooks/session-start" "Preview includes session-start hook"
    assert_contains "$preview_section" "hooks/session-start-codex" "Preview includes Codex session-start hook"
    assert_contains "$preview_section" "hooks/run-hook.cmd" "Preview includes hook command wrapper"
    assert_contains "$preview_section" ".private-journal/keep.txt" "Preview includes tracked ignored file"
    assert_not_contains "$preview_section" ".private-journal/leak.txt" "Preview excludes ignored untracked file"
    assert_not_contains "$preview_section" "ignored-cache/" "Preview excludes pure ignored directories"
    assert_not_contains "$preview_section" "evals/" "Preview excludes eval harness"
    assert_not_contains "$preview_section" ".gitmodules" "Preview excludes repo submodule metadata"
    assert_not_contains "$preview_section" ".pre-commit-config.yaml" "Preview excludes repo pre-commit config"
    assert_not_contains "$preview_output" "Overlay file (.codex-plugin/plugin.json) will be regenerated" "Preview omits overlay regeneration note"
    assert_not_contains "$preview_output" "Assets (superpowers-small.svg, app-icon.png) will be seeded from" "Preview omits assets seeding note"
    assert_contains "$preview_section" "skills/example/SKILL.md" "Preview reflects dirty tracked destination file"
    assert_not_matches "$preview_section" "\\*deleting +skills/example/agents/openai\\.yaml" "Preview preserves destination-owned OpenAI agent metadata"
    assert_current_branch "$dest" "$dest_branch" "Preview leaves destination checkout on its original branch"
    assert_branch_absent "$dest" "sync/supersuit-*" "Preview does not create sync branch in destination checkout"

    echo ""
    echo "Mixed-directory assertions..."
    assert_equals "$mixed_only_status" "0" "Mixed ignored directory preview exits successfully under /bin/bash"
    assert_contains "$mixed_only_output" ".private-journal/keep.txt" "Mixed ignored directory preview still includes tracked ignored file"
    assert_not_contains "$mixed_only_output" "ignored-cache/" "Mixed ignored directory preview has no pure ignored directory fixture"

    echo ""
    echo "Convergence assertions..."
    assert_equals "$stale_preview_status" "0" "Stale ignored destination preview exits successfully"
    assert_matches "$stale_preview_section" "\\*deleting +\\.kimi-plugin/plugin\\.json" "Preview deletes stale Kimi manifest from Codex plugin"
    assert_matches "$stale_preview_section" "\\*deleting +\\.private-journal/leak\\.txt" "Preview deletes stale ignored destination file"

    echo ""
    echo "Bootstrap assertions..."
    assert_equals "$bootstrap_status" "0" "Bootstrap preview exits successfully"
    assert_contains "$bootstrap_output" "Mode:     BOOTSTRAP (creating plugins/supersuit/ when absent)" "Bootstrap preview describes directory creation"
    assert_not_contains "$bootstrap_output" "Assets:" "Bootstrap preview omits external assets path"
    assert_contains "$bootstrap_output" "Dry run only. Nothing was changed or pushed." "Bootstrap preview remains dry-run only"
    assert_path_absent "$bootstrap_dest/plugins/supersuit" "Bootstrap preview does not create destination plugin directory"
    assert_current_branch "$bootstrap_dest" "$bootstrap_dest_branch" "Bootstrap preview leaves destination checkout on its original branch"
    assert_branch_absent "$bootstrap_dest" "bootstrap/supersuit-*" "Bootstrap preview does not create bootstrap branch in destination checkout"

    echo ""
    echo "Apply assertions..."
    assert_equals "$dirty_apply_status" "1" "Dirty local apply exits with failure"
    assert_contains "$dirty_apply_output" "ERROR: local checkout has uncommitted changes under 'plugins/supersuit'" "Dirty local apply reports protected destination path"
    assert_current_branch "$dirty_apply_dest" "$dirty_apply_dest_branch" "Dirty local apply leaves destination checkout on its original branch"
    assert_branch_absent "$dirty_apply_dest" "sync/supersuit-*" "Dirty local apply does not create sync branch in destination checkout"
    assert_file_equals "$dirty_skill_path" "# Example Skill

Locally modified fixture content." "Dirty local apply preserves tracked working-tree file content"
    assert_equals "$noop_apply_status" "0" "Clean no-op local apply exits successfully"
    assert_contains "$noop_apply_output" "No changes — embedded plugin was already in sync with upstream" "Clean no-op local apply reports no changes"
    assert_current_branch "$noop_apply_dest" "$noop_apply_dest_branch" "Clean no-op local apply leaves destination checkout on its original branch"
    assert_branch_absent "$noop_apply_dest" "sync/supersuit-*" "Clean no-op local apply does not create sync branch in destination checkout"
    assert_file_equals "$noop_openai_metadata_path" "interface:
  display_name: \"Example\"
  short_description: \"Destination-owned OpenAI metadata\"" "Clean no-op local apply preserves OpenAI agent metadata"

    echo ""
    echo "Missing manifest assertions..."
    assert_equals "$missing_manifest_status" "1" "Missing manifest exits with failure"
    assert_contains "$missing_manifest_output" "ERROR: committed Codex manifest missing at" "Missing manifest reports committed manifest path"

    echo ""
    echo "Help assertions..."
    assert_not_contains "$help_output" "--assets-src" "Help omits --assets-src"
    assert_contains "$help_output" "--fork" "Help documents --fork dest"
    assert_contains "$help_output" "CODEX_PLUGINS_FORK" "Help documents CODEX_PLUGINS_FORK dest"
    assert_contains "$help_output" "must already exist" "Help says dest repo must already exist"
    assert_not_contains "$help_output" "jeighty/openai-codex-plugins" "Help does not imply a default jeighty Codex plugins repo"

    echo ""
    echo "Destination dest-required assertions..."
    assert_equals "$missing_fork_status" "1" "Non-local run without dest exits with failure"
    assert_contains "$missing_fork_output" "CODEX_PLUGINS_FORK" "Missing dest names CODEX_PLUGINS_FORK"
    assert_contains "$missing_fork_output" "--fork" "Missing dest names --fork"
    assert_contains "$missing_fork_output" "must already exist" "Missing dest says dest repo must already exist"
    assert_not_contains "$missing_fork_output" "Cloning " "Missing dest fails before clone"
    assert_not_contains "$missing_fork_log" "repo clone" "Missing dest does not invoke gh repo clone"
    assert_equals "$uncloneable_status" "1" "Non-local run with uncloneable dest exits with failure"
    assert_contains "$uncloneable_output" "$uncloneable_fork" "Uncloneable dest names the dest repo"
    assert_contains "$uncloneable_output" "must already exist" "Uncloneable dest says dest repo must already exist"
    assert_not_contains "$uncloneable_output" "Cloning " "Uncloneable dest fails before clone"
    assert_not_contains "$uncloneable_log" "repo clone" "Uncloneable dest does not invoke gh repo clone"

    echo ""
    echo "Source assertions..."
    assert_not_contains "$script_source" "regenerated inline" "Source drops regenerated inline phrasing"
    assert_not_contains "$script_source" "Brand Assets directory" "Source drops Brand Assets directory phrasing"
    assert_not_contains "$script_source" "--assets-src" "Source drops --assets-src"
    assert_not_contains "$script_source" "jeighty/openai-codex-plugins" "Source has no baked-in jeighty Codex plugins dest"
    assert_not_contains "$script_source" "prime-radiant-inc/openai-codex-plugins" "Source has no baked-in Prime Radiant Codex plugins dest"
    assert_not_matches "$script_source" 'CODEX_PLUGINS_FORK:-[^}"[:space:]]' "Source has no non-empty CODEX_PLUGINS_FORK default"

    if [[ $FAILURES -ne 0 ]]; then
        echo ""
        echo "FAILED: $FAILURES assertion(s) failed."
        exit 1
    fi

    echo ""
    echo "PASS"
}

main "$@"
