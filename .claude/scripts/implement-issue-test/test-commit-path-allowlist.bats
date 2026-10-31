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
