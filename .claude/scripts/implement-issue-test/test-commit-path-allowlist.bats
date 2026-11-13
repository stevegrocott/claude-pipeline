#!/usr/bin/env bats
#
# test-commit-path-allowlist.bats
# Direct tests for guard_commit_path_allowlist() (issue #978): stylesheet
# admission, the non-overridable .github/workflows/** denylist, and the
# rejection message's extension + suggested EXTRA_COMMIT_PATHS override.
#
# The guard runs under `set -uo pipefail` in the real orchestrator, so each
# case calls it through a wrapper that enables the same options.

load 'helpers/test-helper.bash'

setup() {
    setup_test_env
    install_mocks

    export LOG_BASE="$TEST_TMP/logs/test"
    export LOG_FILE="$LOG_BASE/orchestrator.log"
    mkdir -p "$LOG_BASE"

    mkdir -p "$TEST_TMP/repo"
    cd "$TEST_TMP/repo"
    git init -q
    git checkout -q -b main
    echo "initial" > README.md
    git add README.md
    git commit -q -m "initial"

    source_orchestrator_functions
}

teardown() {
    teardown_test_env
}

# commit_paths <path>... — create each file and commit them together.
commit_paths() {
    local p
    cd "$TEST_TMP/repo"
    for p in "$@"; do
        mkdir -p "$(dirname "$p")"
        echo "content" > "$p"
        git add "$p"
    done
    git commit -q -m "add $*"
}

# run_guard [EXTRA_COMMIT_PATHS] — run the guard on HEAD under set -uo pipefail.
# An empty/absent argument leaves EXTRA_COMMIT_PATHS unset.
run_guard() {
    local extra="${1:-}"
    local wrapper="$TEST_TMP/guard_wrapper.sh"
    {
        echo '#!/usr/bin/env bash'
        echo 'set -uo pipefail'
        echo "source \"$TEST_TMP/orchestrator_functions.bash\""
        echo 'unset EXTRA_COMMIT_PATHS'
        [[ -n "$extra" ]] && printf 'export EXTRA_COMMIT_PATHS=%q\n' "$extra"
        echo "export LOG_FILE=\"$LOG_FILE\""
        echo "guard_commit_path_allowlist \"$TEST_TMP/repo\" HEAD"
    } > "$wrapper"
    chmod +x "$wrapper"
    run "$wrapper"
}

# =============================================================================
# Stylesheet admission (AC1, AC2)
# =============================================================================

@test "admits a .css-only commit with no EXTRA_COMMIT_PATHS" {
    commit_paths apps/frontend/src/app/globals.css
    run_guard
    [ "$status" -eq 0 ] || fail "Expected .css admitted. Got: $output"
}

@test "admits .scss, .sass, .less and .styl on the same basis" {
    local ext
    for ext in scss sass less styl; do
        commit_paths "styles/theme.$ext"
        run_guard
        [ "$status" -eq 0 ] || fail "Expected .$ext admitted. Got: $output"
    done
}

@test "admits a stylesheet committed alongside a .tsx file" {
    commit_paths src/Button.tsx src/Button.css
    run_guard
    [ "$status" -eq 0 ] || fail "Expected mixed commit admitted. Got: $output"
}

# =============================================================================
# Denylist precedence (AC3)
# =============================================================================

@test "rejects .github/workflows/** with no EXTRA_COMMIT_PATHS" {
    commit_paths .github/workflows/ci.yml
    run_guard
    [ "$status" -eq 1 ]
    [[ "$output" == *".github/workflows/ci.yml"* ]] || \
        fail "Expected workflow path flagged. Got: $output"
}

@test "rejects .github/workflows/** even when EXTRA_COMMIT_PATHS names it" {
    commit_paths .github/workflows/ci.yml
    run_guard '.github/workflows/**'
    [ "$status" -eq 1 ]
    [[ "$output" == *".github/workflows/ci.yml"* ]] || \
        fail "Expected workflow path still flagged. Got: $output"
}

@test "hard-denied path message does not advertise EXTRA_COMMIT_PATHS remedy" {
    commit_paths .github/workflows/ci.yml
    run_guard
    [ "$status" -eq 1 ]
    [[ "$output" == *"not overridable"* ]] || \
        fail "Expected not-overridable notice. Got: $output"
    [[ "$output" != *"EXTRA_COMMIT_PATHS='"* ]] || \
        fail "Hard-denied path advertised a remedy. Got: $output"
}

@test "mixed commit suggests EXTRA_COMMIT_PATHS only for the overridable path" {
    commit_paths .github/workflows/ci.yml data/x.csv
    run_guard
    [ "$status" -eq 1 ]
    [[ "$output" == *"EXTRA_COMMIT_PATHS='data/*.csv'"* ]] || \
        fail "Expected csv suggestion. Got: $output"
    [[ "$output" != *"workflows/*.yml"* ]] || \
        fail "Suggestion leaked the hard-denied path. Got: $output"
}

@test "rejects a workflow file even when the extension is otherwise allowlisted" {
    commit_paths .github/workflows/deploy.js
    run_guard '*'
    [ "$status" -eq 1 ]
}

@test "admitting a stylesheet does not admit a workflow in the same commit" {
    commit_paths src/app.css .github/workflows/ci.yml
    run_guard '.github/workflows/**'
    [ "$status" -eq 1 ]
    [[ "$output" == *".github/workflows/ci.yml"* ]] || \
        fail "Expected workflow path flagged. Got: $output"
    [[ "$output" != *"src/app.css"* ]] || \
        fail "Stylesheet must not be flagged. Got: $output"
}

# =============================================================================
# Rejection message (AC4)
# =============================================================================

@test "rejection message names the unrecognised extension" {
    commit_paths apps/frontend/data/seed.xyz
    run_guard
    [ "$status" -eq 1 ]
    # Strip the offending path so only a separately-named extension can match.
    local rest="${output//apps\/frontend\/data\/seed.xyz/}"
    [[ "$rest" == *"xyz"* ]] || \
        fail "Expected extension 'xyz' named apart from the path. Got: $output"
}

@test "rejection message includes a copy-pasteable EXTRA_COMMIT_PATHS value" {
    commit_paths apps/frontend/data/seed.csv
    run_guard
    [ "$status" -eq 1 ]
    [[ "$output" == *"EXTRA_COMMIT_PATHS='"*"*.csv'"* ]] || \
        fail "Expected EXTRA_COMMIT_PATHS='...*.csv' suggestion. Got: $output"
    [[ "$output" == *"apps/frontend/data"* ]] || \
        fail "Expected suggestion derived from the rejected directory. Got: $output"
}

@test "the suggested EXTRA_COMMIT_PATHS value actually admits the rejected path" {
    commit_paths apps/frontend/data/seed.csv
    run_guard
    [ "$status" -eq 1 ]

    local suggestion
    suggestion=$(printf '%s\n' "$output" \
        | grep -o "EXTRA_COMMIT_PATHS='[^']*'" | head -1)
    [[ -n "$suggestion" ]] || fail "No suggestion found. Got: $output"
    suggestion="${suggestion#EXTRA_COMMIT_PATHS=\'}"
    suggestion="${suggestion%\'}"

    run_guard "$suggestion"
    [ "$status" -eq 0 ] || fail "Suggested override '$suggestion' did not admit path. Got: $output"
}

# =============================================================================
# Cross-gate agreement (issue #928 AC4)
#
# Intake (assert_issue_valid) and the commit guard must classify every path
# the same way: a path intake accepts must be committable, and a path the
# guard hard-denies must be refused at intake. Both gates are driven over one
# shared fixture set so a change to either side that makes them diverge fails
# here. issue-body-lib.sh is sourced in a separate bash process because the
# orchestrator deliberately does not share its namespace.
# =============================================================================

# Paths both gates must agree on. Format: <path>|<admit|deny>.
CROSS_GATE_FIXTURES=(
    "src/app.ts|admit"
    ".claude/scripts/implement-issue-test/helpers/test-helper.bash|admit"
    ".claude/scripts/foo.sh|admit"
    "docs/guide.md|admit"
    "styles/site.scss|admit"
    ".github/workflows/ci.yml|deny"
)

# Overridable-deny paths (class 1): refused by BOTH gates by default and
# admitted by BOTH once EXTRA_COMMIT_PATHS matches. Format: <path>|<override glob>.
OVERRIDABLE_FIXTURES=(
    "data/export.csv|data/*.csv"
    "config/app.yml|config/*.yml"
)

# intake_accepts <path> [EXTRA_COMMIT_PATHS] — (path must exist under the repo)
# 0 if assert_issue_valid accepts a body declaring it. Empty/absent override
# leaves EXTRA_COMMIT_PATHS unset, matching run_guard.
intake_accepts() {
    local path="$1" extra="${2:-}"
    local lib="${TEST_DIR}/../issue-body-lib.sh"
    local body
    body=$(printf '## Acceptance Criteria\n\n- [ ] It works\n\n## Implementation Tasks\n\n- [ ] `[default]` **(S)** Change it — `%s`\n' "$path")
    ISSUE_BODY_LIB="$lib" ISSUE_BODY_REPO_ROOT="$TEST_TMP/repo" BODY="$body" EXTRA="$extra" \
        run bash -c 'unset EXTRA_COMMIT_PATHS; [[ -n "$EXTRA" ]] && export EXTRA_COMMIT_PATHS="$EXTRA"; source "$ISSUE_BODY_LIB" && assert_issue_valid "$BODY"'
    return "$status"
}

@test "cross-gate: intake and commit guard agree on every shared fixture" {
    local fixture path expect intake_rc guard_rc mismatches=""
    for fixture in "${CROSS_GATE_FIXTURES[@]}"; do
        path="${fixture%%|*}"
        expect="${fixture##*|}"

        # Commit first: intake resolves declared paths against the repo root,
        # so an absent file would be refused for the wrong reason.
        commit_paths "$path"
        intake_accepts "$path" && intake_rc=0 || intake_rc=1

        run_guard
        guard_rc="$status"

        if [[ "$expect" == admit ]]; then
            { (( intake_rc == 0 )) && (( guard_rc == 0 )); } \
                || mismatches+="  $path: expected both to admit (intake=$intake_rc guard=$guard_rc)"$'\n'
        else
            { (( intake_rc != 0 )) && (( guard_rc != 0 )); } \
                || mismatches+="  $path: expected both to deny (intake=$intake_rc guard=$guard_rc)"$'\n'
        fi
    done
    [[ -z "$mismatches" ]] || fail "Gates disagree:"$'\n'"$mismatches"
}

@test "cross-gate: both gates agree under an empty and an admitting override" {
    local fixture path glob mismatches="" intake_rc guard_rc
    for fixture in "${OVERRIDABLE_FIXTURES[@]}"; do
        path="${fixture%%|*}"
        glob="${fixture##*|}"
        commit_paths "$path"

        # Admitting override: both gates must admit.
        intake_accepts "$path" "$glob" && intake_rc=0 || intake_rc=1
        run_guard "$glob"
        guard_rc="$status"
        { (( intake_rc == 0 )) && (( guard_rc == 0 )); } \
            || mismatches+="  $path: expected both to admit under override $glob (intake=$intake_rc guard=$guard_rc)"$'\n'

        # Empty override: both gates must refuse. Runs second because a
        # guard refusal reverts the commit, which would invalidate the fixture.
        intake_accepts "$path" && intake_rc=0 || intake_rc=1
        run_guard
        guard_rc="$status"
        { (( intake_rc != 0 )) && (( guard_rc != 0 )); } \
            || mismatches+="  $path: expected both to refuse with no override (intake=$intake_rc guard=$guard_rc)"$'\n'
    done
    [[ -z "$mismatches" ]] || fail "Gates disagree:"$'\n'"$mismatches"
}
