#!/usr/bin/env bats
#
# test-surgical-fast-path.bats
#
# Tests for the triage stage and surgical fast-path execution.
#
# Scope: shell-side post-processing logic and fast-path script behavior.
# Real-Claude prompt-quality tests live in .claude/scripts/triage-validate.sh.
#

load 'helpers/test-helper.bash'

setup() {
    setup_test_env
    install_mocks
    install_extended_mocks

    # Resolve fixtures via SCRIPT_DIR (stable across bats's per-test temp dir).
    # Cache the real path before source_orchestrator_functions runs — that
    # function sources orchestrator code which contains its own SCRIPT_DIR=
    # assignment and would otherwise overwrite this to $TEST_TMP.
    REAL_SCRIPT_DIR="$SCRIPT_DIR"
    FIXTURE_DIR="$REAL_SCRIPT_DIR/implement-issue-test/fixtures/triage"

    export ISSUE_NUMBER=2836
    export BASE_BRANCH=main
    export BRANCH="feature/issue-2836"
    export STATUS_FILE="$TEST_TMP/status.json"
    export LOG_BASE="$TEST_TMP/logs/test"
    export LOG_FILE="$LOG_BASE/orchestrator.log"
    export STAGE_COUNTER=0
    export SCHEMA_DIR="$TEST_TMP/schemas"
    # Force PATH lookup so the mock claude/git/gh binaries in $TEST_TMP/bin
    # are used instead of any installed binary.
    export CLAUDE_CLI=claude

    mkdir -p "$LOG_BASE/stages" "$LOG_BASE/context" "$SCHEMA_DIR"

    # Make schemas available to run_stage
    for s in implement-issue-implement implement-issue-test implement-issue-review \
             implement-issue-fix implement-issue-simplify implement-issue-triage \
             implement-issue-parse; do
        if [[ -f "$SCRIPT_DIR/schemas/${s}.json" ]]; then
            cp "$SCRIPT_DIR/schemas/${s}.json" "$SCHEMA_DIR/${s}.json"
        else
            echo '{"type":"object"}' > "$SCHEMA_DIR/${s}.json"
        fi
    done

    source_orchestrator_functions || true

    # Best-effort init_status; tests that don't need it tolerate failure
    init_status 2>/dev/null || true

    unset DISABLE_SURGICAL_FAST_PATH TRIAGE_MODEL || true
    unset MOCK_GIT_DIRTY MOCK_GIT_HOOK_FAILURE MOCK_GIT_PUSH_EXIT_CODE \
          MOCK_GIT_GREP_FILE_COUNT MOCK_GH_MERGE_STATE \
          MOCK_GH_MERGE_STATE_SEQ MOCK_GH_MERGE_STATE_CTR \
          MOCK_GH_PR_CREATE_EXIT_CODE MOCK_GH_PR_MERGE_EXIT_CODE \
          MOCK_GIT_STASH_PUSH_EXIT_CODE MOCK_GIT_STASH_POP_EXIT_CODE \
          MOCK_GIT_POST_IMPL_FILES || true
    # Clear stash marker files left over from prior tests (per-test $TEST_TMP
    # is fresh, but be explicit for resume-style tests that re-enter setup).
    rm -f "$TEST_TMP/git-stash-pushed" "$TEST_TMP/git-stash-popped" || true
    unset FAST_PATH_MERGE_CHECK_ATTEMPTS FAST_PATH_MERGE_CHECK_DELAY || true

    # Default: zero retry delay so tests don't sleep.
    export FAST_PATH_MERGE_CHECK_DELAY=0
}

teardown() {
    teardown_test_env
}

# ============================================================================
# Mock helpers
# ============================================================================

# Build a Claude triage response envelope.
# Args:
#   $1 route                       fast-path | full
#   $2 confidence                  high | medium | low
#   $3 disqualifying_criterion     null OR criterion name in quotes-handled
#   $4 established_pattern_grep    null OR regex
#   $5 failed_criterion (optional) name of single criterion to mark failed
make_triage_response() {
    local route="$1" conf="$2" dq="$3" pattern="$4" failed="${5:-}"

    _crit() {
        local name="$1"
        if [[ "$failed" == "$name" ]]; then
            printf '{"passed":false,"reason":"failed-for-test"}'
        else
            printf '{"passed":true,"reason":"ok"}'
        fi
    }

    local pat_field
    if [[ "$pattern" == "null" ]]; then
        pat_field='null'
    else
        pat_field="\"$pattern\""
    fi
    local dq_field
    if [[ "$dq" == "null" ]]; then
        dq_field='null'
    else
        dq_field="\"$dq\""
    fi

    cat <<JSON
{
  "is_error": false,
  "result": "Triage decision: $route",
  "structured_output": {
    "route": "$route",
    "criteria": {
      "test_only_scope": $(_crit test_only_scope),
      "surgical_size": $(_crit surgical_size),
      "established_pattern": $(_crit established_pattern),
      "precise_specification": $(_crit precise_specification),
      "benign_failure_mode": $(_crit benign_failure_mode),
      "no_security_concerns": $(_crit no_security_concerns)
    },
    "established_pattern_grep": $pat_field,
    "confidence": "$conf",
    "disqualifying_criterion": $dq_field,
    "summary": "test summary",
    "status": "success"
  }
}
JSON
}

# Write a triage response and tell the mock claude binary to return it.
configure_mock_claude_triage() {
    local resp_file="$TEST_TMP/triage-resp.json"
    "$@" > "$resp_file"
    export MOCK_CLAUDE_RESPONSE="$resp_file"
    export MOCK_CLAUDE_EXIT_CODE=0
}

# Install extended mocks for git and gh that handle triage / fast-path commands.
install_extended_mocks() {
    local mock_bin="$TEST_TMP/bin"
    mkdir -p "$mock_bin"

    # Mock git: handles grep, status, diff, push, commit, checkout, etc.
    cat > "$mock_bin/git" <<'GIT_MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    grep)
        # discard flags up to pattern
        shift
        while [[ "${1:-}" == -* ]]; do shift; done
        n="${MOCK_GIT_GREP_FILE_COUNT:-0}"
        i=1
        while [[ "$i" -le "$n" ]]; do
            echo "stub/file-${i}.ts"
            i=$((i+1))
        done
        exit 0
        ;;
    status)
        # If the working tree was already stashed away by the fast-path's
        # fresh-start handling, status must report clean — otherwise the
        # script would loop on the dirty check after pop.
        if [[ "${MOCK_GIT_DIRTY:-0}" == "1" ]] && [[ ! -f "$TEST_TMP/git-stash-pushed" ]]; then
            echo " M some-file.ts"
        fi
        # Two-phase support: after implement fires, return post-impl files so
        # before/after snapshot tests can assert only the delta is staged.
        if [[ -f "$TEST_TMP/impl-ran" && -n "${MOCK_GIT_POST_IMPL_FILES:-}" ]]; then
            printf '%s\n' "${MOCK_GIT_POST_IMPL_FILES}"
        fi
        exit 0
        ;;
    diff)
        if [[ "${MOCK_GIT_DIRTY:-0}" == "1" ]]; then
            echo "diff --git a/some-file.ts b/some-file.ts"
            exit 0
        fi
        exit 0
        ;;
    stash)
        case "${2:-}" in
            push|save|"")
                : > "$TEST_TMP/git-stash-pushed"
                exit "${MOCK_GIT_STASH_PUSH_EXIT_CODE:-0}"
                ;;
            pop)
                if [[ "${MOCK_GIT_STASH_POP_EXIT_CODE:-0}" != "0" ]]; then
                    echo "CONFLICT (content): Merge conflict in some-file.ts" >&2
                    exit "${MOCK_GIT_STASH_POP_EXIT_CODE}"
                fi
                : > "$TEST_TMP/git-stash-popped"
                rm -f "$TEST_TMP/git-stash-pushed"
                exit 0
                ;;
            *)
                exit 0
                ;;
        esac
        ;;
    checkout|switch)
        exit "${MOCK_GIT_CHECKOUT_EXIT_CODE:-0}"
        ;;
    add)
        # Record staged args so tests can assert which files were staged.
        printf '%s\n' "${@:2}" >> "$TEST_TMP/git-add-args"
        exit 0
        ;;
    commit)
        if [[ "${MOCK_GIT_HOOK_FAILURE:-0}" == "1" ]]; then
            echo "husky - pre-commit hook failed" >&2
            echo "ESLint: 'foo' is defined but never used (no-unused-vars)" >&2
            exit 1
        fi
        echo "[mock] git commit: $*"
        exit 0
        ;;
    push)
        if [[ "${MOCK_GIT_PUSH_EXIT_CODE:-0}" != "0" ]]; then
            echo "remote: rejected" >&2
            exit "${MOCK_GIT_PUSH_EXIT_CODE}"
        fi
        echo "[mock] git push: $*"
        exit 0
        ;;
    rev-parse)
        echo "abc123"
        exit 0
        ;;
    symbolic-ref)
        echo "main"
        exit 0
        ;;
    config)
        exit 0
        ;;
    *)
        echo "[mock] git: $*"
        exit "${MOCK_GIT_EXIT_CODE:-0}"
        ;;
esac
GIT_MOCK
    chmod +x "$mock_bin/git"

    # Override gh mock with a smarter one that handles pr create/view/merge.
    cat > "$mock_bin/gh" <<'GH_MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "pr" ]]; then
    case "${2:-}" in
        create)
            if [[ "${MOCK_GH_PR_CREATE_EXIT_CODE:-0}" != "0" ]]; then
                exit "${MOCK_GH_PR_CREATE_EXIT_CODE}"
            fi
            echo "https://github.com/test/repo/pull/${MOCK_GH_PR_NUMBER:-99}"
            exit 0
            ;;
        view)
            # Find --json arg and respond accordingly.
            json_field=""
            while [[ $# -gt 0 ]]; do
                if [[ "$1" == "--json" ]]; then json_field="$2"; shift 2; continue; fi
                shift
            done
            num="${MOCK_GH_PR_NUMBER:-99}"
            # Sequenced merge state: comma-separated values consumed left-to-right
            # via a counter file. Falls back to MOCK_GH_MERGE_STATE for the
            # single-value case. Lets tests script "UNKNOWN,UNKNOWN,CLEAN".
            if [[ -n "${MOCK_GH_MERGE_STATE_SEQ:-}" ]]; then
                ctr_file="${MOCK_GH_MERGE_STATE_CTR:-/tmp/mock_merge_ctr.$$}"
                idx=0
                if [[ -f "$ctr_file" ]]; then idx=$(cat "$ctr_file"); fi
                IFS=',' read -ra _seq <<< "$MOCK_GH_MERGE_STATE_SEQ"
                # Clamp to last entry once exhausted (for any trailing checks).
                if (( idx >= ${#_seq[@]} )); then idx=$(( ${#_seq[@]} - 1 )); fi
                state="${_seq[$idx]}"
                echo $((idx + 1)) > "$ctr_file"
            else
                state="${MOCK_GH_MERGE_STATE:-CLEAN}"
            fi
            if [[ "$json_field" == *mergeStateStatus* ]]; then
                printf '{"mergeStateStatus":"%s"}\n' "$state"
            elif [[ "$json_field" == *number* ]]; then
                printf '{"number":%s}\n' "$num"
            else
                printf '{}\n'
            fi
            exit 0
            ;;
        merge)
            exit "${MOCK_GH_PR_MERGE_EXIT_CODE:-0}"
            ;;
    esac
fi
echo "[mock] gh: $*"
exit "${MOCK_GH_EXIT_CODE:-0}"
GH_MOCK
    chmod +x "$mock_bin/gh"

    # Override mock claude to drop an impl-ran marker so the git status mock
    # can return different output before vs. after the implement step runs.
    cat > "$mock_bin/claude" <<'CLAUDE_MOCK'
#!/usr/bin/env bash
: > "$TEST_TMP/impl-ran"
if [[ -n "${MOCK_CLAUDE_RESPONSE:-}" && -f "$MOCK_CLAUDE_RESPONSE" ]]; then
    cat "$MOCK_CLAUDE_RESPONSE"
else
    echo '{"result":"mock response","structured_output":{"status":"success"}}'
fi
exit "${MOCK_CLAUDE_EXIT_CODE:-0}"
CLAUDE_MOCK
    chmod +x "$mock_bin/claude"
}

# ============================================================================
# CLASSIFICATION + ROUTING CONTROL (post-processing tests, mocked Claude)
# ============================================================================

@test "01 fast-path response with high confidence + pattern grep ≥3 → route=fast-path" {
    configure_mock_claude_triage make_triage_response fast-path high null 'storageState.*\\.auth/'
    export MOCK_GIT_GREP_FILE_COUNT=5
    cp "$FIXTURE_DIR/issue-2836.md" "$TEST_TMP/issue-body.md"

    run run_triage_stage "$TEST_TMP/issue-body.md"

    [ "$status" -eq 0 ]
    [ -f "$LOG_BASE/triage.json" ]
    assert_json_field "$LOG_BASE/triage.json" '.route' 'fast-path'
    assert_json_field "$LOG_BASE/triage.json" '.confidence' 'high'
    assert_json_field "$LOG_BASE/triage.json" '.pattern_grep_count' '5'
}

@test "02 full-route response → route=full preserved with disqualifying_criterion" {
    configure_mock_claude_triage make_triage_response full high test_only_scope null test_only_scope
    cp "$FIXTURE_DIR/issue-2752.md" "$TEST_TMP/issue-body.md"

    run run_triage_stage "$TEST_TMP/issue-body.md"

    [ "$status" -eq 0 ]
    assert_json_field "$LOG_BASE/triage.json" '.route' 'full'
    assert_json_field "$LOG_BASE/triage.json" '.disqualifying_criterion' 'test_only_scope'
    assert_json_field "$LOG_BASE/triage.json" '.criteria.test_only_scope.passed' 'false'
}

@test "03 fast-path response with confidence=medium → demoted to full" {
    configure_mock_claude_triage make_triage_response fast-path medium null 'pat'
    export MOCK_GIT_GREP_FILE_COUNT=5
    cp "$FIXTURE_DIR/issue-2836.md" "$TEST_TMP/issue-body.md"

    run run_triage_stage "$TEST_TMP/issue-body.md"

    [ "$status" -eq 0 ]
    assert_json_field "$LOG_BASE/triage.json" '.route' 'full'
    assert_json_field "$LOG_BASE/triage.json" '.disqualifying_criterion' 'confidence_low'
}

@test "04 fast-path response with confidence=low → demoted to full" {
    configure_mock_claude_triage make_triage_response fast-path low null 'pat'
    export MOCK_GIT_GREP_FILE_COUNT=5
    cp "$FIXTURE_DIR/issue-2836.md" "$TEST_TMP/issue-body.md"

    run run_triage_stage "$TEST_TMP/issue-body.md"

    [ "$status" -eq 0 ]
    assert_json_field "$LOG_BASE/triage.json" '.route' 'full'
    assert_json_field "$LOG_BASE/triage.json" '.disqualifying_criterion' 'confidence_low'
}

@test "05 fast-path response with established_pattern_grep=null → demoted to full" {
    # Claude itself failed criterion 3 by returning null pattern.
    configure_mock_claude_triage make_triage_response fast-path high established_pattern null established_pattern
    cp "$FIXTURE_DIR/issue-novel-pattern.md" "$TEST_TMP/issue-body.md"

    run run_triage_stage "$TEST_TMP/issue-body.md"

    [ "$status" -eq 0 ]
    assert_json_field "$LOG_BASE/triage.json" '.route' 'full'
    assert_json_field "$LOG_BASE/triage.json" '.disqualifying_criterion' 'established_pattern'
}

@test "06 fast-path response but pattern grep <3 matches → demoted to full" {
    configure_mock_claude_triage make_triage_response fast-path high null 'rare-pattern'
    export MOCK_GIT_GREP_FILE_COUNT=2
    cp "$FIXTURE_DIR/issue-novel-pattern.md" "$TEST_TMP/issue-body.md"

    run run_triage_stage "$TEST_TMP/issue-body.md"

    [ "$status" -eq 0 ]
    assert_json_field "$LOG_BASE/triage.json" '.route' 'full'
    assert_json_field "$LOG_BASE/triage.json" '.disqualifying_criterion' 'established_pattern'
    assert_json_field "$LOG_BASE/triage.json" '.pattern_grep_count' '2'
}

@test "07 fast-path response with pattern grep =3 matches (boundary) → preserved fast-path" {
    configure_mock_claude_triage make_triage_response fast-path high null 'edge-pattern'
    export MOCK_GIT_GREP_FILE_COUNT=3
    cp "$FIXTURE_DIR/issue-2836.md" "$TEST_TMP/issue-body.md"

    run run_triage_stage "$TEST_TMP/issue-body.md"

    [ "$status" -eq 0 ]
    assert_json_field "$LOG_BASE/triage.json" '.route' 'fast-path'
    assert_json_field "$LOG_BASE/triage.json" '.pattern_grep_count' '3'
}

@test "08 DISABLE_SURGICAL_FAST_PATH=1 forces full even on fast-path-eligible response" {
    export DISABLE_SURGICAL_FAST_PATH=1
    configure_mock_claude_triage make_triage_response fast-path high null 'pat'
    export MOCK_GIT_GREP_FILE_COUNT=10
    cp "$FIXTURE_DIR/issue-2836.md" "$TEST_TMP/issue-body.md"

    run run_triage_stage "$TEST_TMP/issue-body.md"

    [ "$status" -eq 0 ]
    assert_json_field "$LOG_BASE/triage.json" '.route' 'full'
    assert_json_field "$LOG_BASE/triage.json" '.kill_switch_engaged' 'true'
}

@test "09 triage.json artifact for full route includes all 6 criteria with reasons" {
    configure_mock_claude_triage make_triage_response full high benign_failure_mode null benign_failure_mode
    cp "$FIXTURE_DIR/issue-2754.md" "$TEST_TMP/issue-body.md"

    run run_triage_stage "$TEST_TMP/issue-body.md"

    [ "$status" -eq 0 ]
    [ -f "$LOG_BASE/triage.json" ]
    for c in test_only_scope surgical_size established_pattern precise_specification \
             benign_failure_mode no_security_concerns; do
        actual=$(jq -r ".criteria.${c}.passed" "$LOG_BASE/triage.json")
        [[ "$actual" == "true" || "$actual" == "false" ]]
        actual=$(jq -r ".criteria.${c}.reason" "$LOG_BASE/triage.json")
        [[ -n "$actual" && "$actual" != "null" ]]
    done
}

@test "10 triage.json artifact for fast-path route includes pattern_grep_count" {
    configure_mock_claude_triage make_triage_response fast-path high null 'storageState'
    export MOCK_GIT_GREP_FILE_COUNT=7
    cp "$FIXTURE_DIR/issue-2839.md" "$TEST_TMP/issue-body.md"

    run run_triage_stage "$TEST_TMP/issue-body.md"

    [ "$status" -eq 0 ]
    assert_json_field "$LOG_BASE/triage.json" '.route' 'fast-path'
    assert_json_field "$LOG_BASE/triage.json" '.pattern_grep_count' '7'
    assert_json_field "$LOG_BASE/triage.json" '.established_pattern_grep' 'storageState'
}

# ============================================================================
# INIT + STATUS SCHEMA SUPERSET
# ============================================================================

@test "11 init_status declares triage and fast_path_* stages" {
    rm -f "$STATUS_FILE"
    init_status

    [ -f "$STATUS_FILE" ]
    assert_json_field "$STATUS_FILE" '.stages.triage.status' 'pending'
    assert_json_field "$STATUS_FILE" '.stages.fast_path_implement.status' 'pending'
    assert_json_field "$STATUS_FILE" '.stages.fast_path_pr.status' 'pending'
    assert_json_field "$STATUS_FILE" '.stages.fast_path_merge.status' 'pending'
    assert_json_field "$STATUS_FILE" '.route' 'null'
}

@test "12 status.json schema is a superset for both routes" {
    # Required existing keys must remain after triage stage updates status.
    configure_mock_claude_triage make_triage_response full high test_only_scope null test_only_scope
    cp "$FIXTURE_DIR/issue-2752.md" "$TEST_TMP/issue-body.md"
    run_triage_stage "$TEST_TMP/issue-body.md" || true

    for k in state issue base_branch branch current_stage stages tasks \
             quality_iterations test_iterations pr_review_iterations \
             last_update log_dir escalations; do
        present=$(jq -e --arg k "$k" 'has($k)' "$STATUS_FILE")
        [[ "$present" == "true" ]]
    done

    # New optional top-level field present
    present=$(jq -e 'has("route")' "$STATUS_FILE")
    [[ "$present" == "true" ]]
}

# ============================================================================
# FAST-PATH SCRIPT EXECUTION
# ============================================================================

# Helper to invoke surgical-fast-path.sh with the test environment.
invoke_fast_path_script() {
    "$SCRIPT_DIR/surgical-fast-path.sh"
}

@test "13 fast-path on RESUME with dirty tree → bails state=failed, error=dirty_tree" {
    # Resume scenario: a prior run already completed fast_path_implement, so
    # any dirty tree we encounter now is leftover scratch the operator needs
    # to investigate. The script must still bail with dirty_tree.
    export MOCK_GIT_DIRTY=1
    # Mark fast_path_implement as completed to simulate a resumed run.
    jq '.stages.fast_path_implement.status = "completed"' \
        "$STATUS_FILE" > "$STATUS_FILE.tmp"
    mv "$STATUS_FILE.tmp" "$STATUS_FILE"

    run "$REAL_SCRIPT_DIR/surgical-fast-path.sh"

    [ "$status" -ne 0 ]
    assert_json_field "$STATUS_FILE" '.state' 'failed'
    assert_json_field "$STATUS_FILE" '.error' 'dirty_tree'
    # On resume we must NOT have stashed — that would silently lose the
    # operator's investigation context.
    [[ ! -f "$TEST_TMP/git-stash-pushed" ]]
}

@test "13a fast-path on FRESH start with dirty tree → stashes, proceeds, pops" {
    # Fresh-start scenario: fast_path_implement still pending. Unrelated
    # uncommitted changes in the working tree should be stashed away,
    # the fast-path should run normally, and the stash should be popped
    # after branch checkout completes.
    export MOCK_GIT_DIRTY=1
    export MOCK_GH_MERGE_STATE=CLEAN
    export MOCK_GH_PR_NUMBER=99

    run "$REAL_SCRIPT_DIR/surgical-fast-path.sh"

    [ "$status" -eq 0 ]
    assert_json_field "$STATUS_FILE" '.state' 'completed'
    # Stash push must have happened so the dirty tree didn't block checkout.
    [[ -f "$TEST_TMP/git-stash-popped" ]]
    # And the operator's uncommitted work must have been restored.
    assert_json_field "$STATUS_FILE" '.stages.fast_path_implement.status' 'completed'
    assert_json_field "$STATUS_FILE" '.stages.fast_path_pr.status' 'completed'
    assert_json_field "$STATUS_FILE" '.stages.fast_path_merge.status' 'completed'
}

@test "13b fast-path stash pop conflict on fresh start → bails error=stash_pop_conflict" {
    # If git stash pop conflicts (the branch checkout modified files that
    # overlap the stash), the script must surface this as a distinct error
    # so the operator can recover their uncommitted work — never silently
    # continue and risk losing it.
    export MOCK_GIT_DIRTY=1
    export MOCK_GIT_STASH_POP_EXIT_CODE=1

    run "$REAL_SCRIPT_DIR/surgical-fast-path.sh"

    [ "$status" -ne 0 ]
    assert_json_field "$STATUS_FILE" '.state' 'failed'
    assert_json_field "$STATUS_FILE" '.error' 'stash_pop_conflict'
    # Stash push happened (so the dirty check passed and checkout proceeded)
    # but pop failed — the marker for a successful pop must NOT be present.
    [[ -f "$TEST_TMP/git-stash-pushed" ]]
    [[ ! -f "$TEST_TMP/git-stash-popped" ]]
}

@test "14 fast-path bails on hook failure → captures stderr to triage.json.hook_failure_output" {
    export MOCK_GIT_HOOK_FAILURE=1
    # triage.json must already exist from a prior triage stage call
    mkdir -p "$LOG_BASE"
    echo '{"route":"fast-path"}' > "$LOG_BASE/triage.json"

    run "$REAL_SCRIPT_DIR/surgical-fast-path.sh"

    [ "$status" -ne 0 ]
    assert_json_field "$STATUS_FILE" '.state' 'failed'
    assert_json_field "$STATUS_FILE" '.error' 'pre_commit_hook_failed'
    hook_out=$(jq -r '.hook_failure_output // ""' "$LOG_BASE/triage.json")
    [[ "$hook_out" == *"husky"* || "$hook_out" == *"pre-commit"* ]]
}

@test "15 fast-path bails cleanly on push rejection → state=failed, error=push_rejected" {
    export MOCK_GIT_PUSH_EXIT_CODE=1

    run "$REAL_SCRIPT_DIR/surgical-fast-path.sh"

    [ "$status" -ne 0 ]
    assert_json_field "$STATUS_FILE" '.state' 'failed'
    assert_json_field "$STATUS_FILE" '.error' 'push_rejected'
}

@test "16 fast-path bails when mergeStateStatus is not CLEAN/HAS_HOOKS → no merge attempted" {
    export MOCK_GH_MERGE_STATE=DIRTY

    run "$REAL_SCRIPT_DIR/surgical-fast-path.sh"

    [ "$status" -ne 0 ]
    assert_json_field "$STATUS_FILE" '.state' 'failed'
    # Specific error name documents what blocked
    err=$(jq -r '.error // ""' "$STATUS_FILE")
    [[ "$err" == *"merge"* ]] || [[ "$err" == *"unsafe"* ]]
    # fast_path_merge must NOT be marked completed
    merge_status=$(jq -r '.stages.fast_path_merge.status // "pending"' "$STATUS_FILE")
    [[ "$merge_status" != "completed" ]]
}

@test "17 fast-path happy path → branch + PR + merge succeed, state=completed" {
    export MOCK_GH_MERGE_STATE=CLEAN
    export MOCK_GH_PR_NUMBER=99

    run "$REAL_SCRIPT_DIR/surgical-fast-path.sh"

    [ "$status" -eq 0 ]
    assert_json_field "$STATUS_FILE" '.state' 'completed'
    assert_json_field "$STATUS_FILE" '.stages.fast_path_implement.status' 'completed'
    assert_json_field "$STATUS_FILE" '.stages.fast_path_pr.status' 'completed'
    assert_json_field "$STATUS_FILE" '.stages.fast_path_merge.status' 'completed'
}

@test "18 DISABLE_SURGICAL_FAST_PATH=1 honored when fast-path script invoked directly" {
    [ -x "$REAL_SCRIPT_DIR/surgical-fast-path.sh" ] || skip "fast-path script not implemented yet"

    export DISABLE_SURGICAL_FAST_PATH=1
    export MOCK_GH_MERGE_STATE=CLEAN

    run "$REAL_SCRIPT_DIR/surgical-fast-path.sh"

    # Must exit non-zero (refused to run) AND not have merged
    [ "$status" -ne 0 ]
    # And the message should explicitly mention the kill switch so an operator
    # debugging "why didn't the fast-path run?" finds the answer.
    [[ "$output" == *"DISABLE_SURGICAL_FAST_PATH"* ]]
    merge_status=$(jq -r '.stages.fast_path_merge.status // "pending"' "$STATUS_FILE")
    [[ "$merge_status" != "completed" ]]
}

# ============================================================================
# Review-fix coverage: blockers from spec-review (findings 1, 3, 4, 5)
# ============================================================================

# Helper: hand-craft a triage response with an arbitrary pattern string so we
# can inject control characters that make_triage_response's printf would munge.
write_triage_response_with_pattern() {
    local route="$1" conf="$2" pattern="$3"
    local resp_file="$TEST_TMP/triage-resp.json"
    jq -n \
        --arg route "$route" \
        --arg conf "$conf" \
        --arg pattern "$pattern" \
        '{is_error:false, result:"triage", structured_output:{
            route:$route,
            criteria:{
                test_only_scope:{passed:true,reason:"ok"},
                surgical_size:{passed:true,reason:"ok"},
                established_pattern:{passed:true,reason:"ok"},
                precise_specification:{passed:true,reason:"ok"},
                benign_failure_mode:{passed:true,reason:"ok"},
                no_security_concerns:{passed:true,reason:"ok"}
            },
            established_pattern_grep:$pattern,
            confidence:$conf,
            disqualifying_criterion:null,
            summary:"test",
            status:"success"
        }}' > "$resp_file"
    export MOCK_CLAUDE_RESPONSE="$resp_file"
    export MOCK_CLAUDE_EXIT_CODE=0
}

@test "19 newline-in-pattern is rejected before git grep → demoted to full" {
    # Fix #1: a pattern containing \n would, if passed to git grep -E, match
    # files containing EITHER alternation branch. A crafted "real-token\n."
    # would falsely match arbitrary files. Verify the shell rejects multi-line
    # patterns up front and never invokes git grep on them.
    write_triage_response_with_pattern fast-path high $'storageState\n.'
    # Set grep mock to a high count — if the shell incorrectly ran git grep,
    # the route would stay fast-path. The bug fix forces full BEFORE grep runs.
    export MOCK_GIT_GREP_FILE_COUNT=99
    cp "$FIXTURE_DIR/issue-2836.md" "$TEST_TMP/issue-body.md"

    run run_triage_stage "$TEST_TMP/issue-body.md"

    [ "$status" -eq 0 ]
    assert_json_field "$LOG_BASE/triage.json" '.route' 'full'
    assert_json_field "$LOG_BASE/triage.json" '.disqualifying_criterion' 'established_pattern'
    # pattern_grep_count should still be 0 because we short-circuited.
    assert_json_field "$LOG_BASE/triage.json" '.pattern_grep_count' '0'
}

@test "20 implement returning status:error → bail implement_returned_error" {
    # Fix #3: process exit 0 + structured_output.status="error" must NOT
    # proceed to commit. Otherwise the failure surfaces as a confusing
    # pre_commit_hook_failed and masks the real cause.
    [ -x "$REAL_SCRIPT_DIR/surgical-fast-path.sh" ] || skip "fast-path not present"

    # Mock implement to return success-exit but error-status.
    cat > "$TEST_TMP/implement-resp.json" <<'JSON'
{"is_error":false,"result":"implement","structured_output":{"status":"error","summary":"could not find file foo.ts"}}
JSON
    export MOCK_CLAUDE_RESPONSE="$TEST_TMP/implement-resp.json"
    export MOCK_CLAUDE_EXIT_CODE=0

    run "$REAL_SCRIPT_DIR/surgical-fast-path.sh"

    [ "$status" -ne 0 ]
    assert_json_field "$STATUS_FILE" '.state' 'failed'
    err=$(jq -r '.error // ""' "$STATUS_FILE")
    [[ "$err" == implement_returned_* ]]
    # Crucially, the script must NOT have advanced past implement. fast_path_pr
    # should be untouched (still pending), proving no commit attempt.
    pr_stage_status=$(jq -r '.stages.fast_path_pr.status // "pending"' "$STATUS_FILE")
    [[ "$pr_stage_status" == "pending" || "$pr_stage_status" == "" ]]
}

@test "21 mergeStateStatus=UNKNOWN retries and succeeds when state settles to CLEAN" {
    # Fix #4: GitHub returns UNKNOWN for ~2-10s after PR creation. Without
    # retry the fast-path bails on virtually every real PR. Verify the loop
    # polls until CLEAN and proceeds.
    [ -x "$REAL_SCRIPT_DIR/surgical-fast-path.sh" ] || skip "fast-path not present"

    export MOCK_GH_MERGE_STATE_SEQ="UNKNOWN,UNKNOWN,CLEAN"
    export MOCK_GH_MERGE_STATE_CTR="$TEST_TMP/merge_ctr"
    export MOCK_GH_PR_NUMBER=42
    export FAST_PATH_MERGE_CHECK_ATTEMPTS=5
    export FAST_PATH_MERGE_CHECK_DELAY=0

    run "$REAL_SCRIPT_DIR/surgical-fast-path.sh"

    [ "$status" -eq 0 ]
    assert_json_field "$STATUS_FILE" '.state' 'completed'
    assert_json_field "$STATUS_FILE" '.stages.fast_path_merge.status' 'completed'
    # Counter should record at least 3 polls (the third returned CLEAN).
    polls=$(cat "$TEST_TMP/merge_ctr" 2>/dev/null || echo 0)
    [[ "$polls" -ge 3 ]]
}

@test "22 mergeStateStatus stays UNKNOWN after max attempts → bail" {
    # Fix #4 negative case: if UNKNOWN persists (e.g. GitHub backlogged),
    # we still bail rather than blocking forever. Verify a finite attempt
    # cap and a specific error message.
    [ -x "$REAL_SCRIPT_DIR/surgical-fast-path.sh" ] || skip "fast-path not present"

    export MOCK_GH_MERGE_STATE_SEQ="UNKNOWN,UNKNOWN,UNKNOWN,UNKNOWN"
    export MOCK_GH_MERGE_STATE_CTR="$TEST_TMP/merge_ctr"
    export FAST_PATH_MERGE_CHECK_ATTEMPTS=3
    export FAST_PATH_MERGE_CHECK_DELAY=0

    run "$REAL_SCRIPT_DIR/surgical-fast-path.sh"

    [ "$status" -ne 0 ]
    assert_json_field "$STATUS_FILE" '.state' 'failed'
    err=$(jq -r '.error // ""' "$STATUS_FILE")
    [[ "$err" == "unsafe_merge_state_UNKNOWN" ]]
    # Merge must NOT have run.
    merge_status=$(jq -r '.stages.fast_path_merge.status // "pending"' "$STATUS_FILE")
    [[ "$merge_status" != "completed" ]]
}

@test "23 resume: fast_path_implement already completed → skips implement, runs PR + merge" {
    # Fix #5: stage-boundary resume. If fast_path_implement is marked
    # completed in status.json, we skip the implement call entirely and
    # proceed to commit/PR/merge. Verified by setting MOCK_CLAUDE_EXIT_CODE=1
    # — if the script tried to call claude, the run would bail
    # implement_failed; success proves it was skipped.
    [ -x "$REAL_SCRIPT_DIR/surgical-fast-path.sh" ] || skip "fast-path not present"

    # Pre-seed status.json: triage + implement already done.
    _jq_inplace_test() {
        local f="$1"; shift
        jq "$@" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    }
    _jq_inplace_test "$STATUS_FILE" \
        '.stages.fast_path_implement.status = "completed" |
         .stages.fast_path_implement.completed_at = (now | todate)'

    # Make claude calls fail — they should not be reached.
    export MOCK_CLAUDE_EXIT_CODE=1
    export MOCK_GH_MERGE_STATE=CLEAN
    export MOCK_GH_PR_NUMBER=77

    run "$REAL_SCRIPT_DIR/surgical-fast-path.sh"

    [ "$status" -eq 0 ]
    assert_json_field "$STATUS_FILE" '.state' 'completed'
    assert_json_field "$STATUS_FILE" '.stages.fast_path_implement.status' 'completed'
    assert_json_field "$STATUS_FILE" '.stages.fast_path_pr.status' 'completed'
    assert_json_field "$STATUS_FILE" '.stages.fast_path_merge.status' 'completed'
}

@test "24 resume: fast_path_pr already completed → skips commit/push/PR-create, reuses pr_number" {
    # Fix #5: the most common real resume case (rate-limit between PR
    # create and merge). The script must read the stored pr_number from
    # status.json and skip directly to mergeability + merge.
    [ -x "$REAL_SCRIPT_DIR/surgical-fast-path.sh" ] || skip "fast-path not present"

    # Pre-seed status.json: implement + PR already done, with a stored PR#.
    jq '.stages.fast_path_implement.status = "completed" |
        .stages.fast_path_pr.status = "completed" |
        .stages.fast_path_pr.pr_number = 4242' \
        "$STATUS_FILE" > "$STATUS_FILE.tmp" && mv "$STATUS_FILE.tmp" "$STATUS_FILE"

    # Force git commit + push to fail. They must NOT run, or the test bails.
    export MOCK_GIT_HOOK_FAILURE=1
    export MOCK_GIT_PUSH_EXIT_CODE=1
    # And make gh pr create fail too — also must not run.
    export MOCK_GH_PR_CREATE_EXIT_CODE=1
    export MOCK_GH_MERGE_STATE=CLEAN

    run "$REAL_SCRIPT_DIR/surgical-fast-path.sh"

    [ "$status" -eq 0 ]
    assert_json_field "$STATUS_FILE" '.state' 'completed'
    assert_json_field "$STATUS_FILE" '.stages.fast_path_merge.status' 'completed'
    # Stored pr_number must be preserved (proves we read it, didn't overwrite).
    assert_json_field "$STATUS_FILE" '.stages.fast_path_pr.pr_number' '4242'
}

# ============================================================================
# SCOPE-SAFE STAGING (AC1 + AC2 from issue #392)
# ============================================================================

@test "25 only modified files staged — git add receives impl-delta, not -A" {
    # AC1: the fast-path stages only files the implement step changed (via a
    # before/after git status --porcelain snapshot), never the full tree.
    # Verified by recording which args are passed to git add and asserting that
    # -A is absent and the impl file is present.
    [ -x "$REAL_SCRIPT_DIR/surgical-fast-path.sh" ] || skip "fast-path not present"

    # After implement runs, one new file appears in the working tree.
    export MOCK_GIT_POST_IMPL_FILES=" M src/things.test.ts"
    export MOCK_GH_MERGE_STATE=CLEAN
    export MOCK_GH_PR_NUMBER=99

    run "$REAL_SCRIPT_DIR/surgical-fast-path.sh"

    [ "$status" -eq 0 ]
    assert_json_field "$STATUS_FILE" '.state' 'completed'
    # git add must have received the impl file explicitly by path.
    [[ -f "$TEST_TMP/git-add-args" ]]
    grep -qF "src/things.test.ts" "$TEST_TMP/git-add-args"
    # Must NOT have used git add -A (whole-tree staging).
    ! grep -qF -- "-A" "$TEST_TMP/git-add-args"
}

@test "26 guard rejects out-of-scope path in staged delta → bails before commit" {
    # AC2: if the implement step modifies a .claude/ path, the scope guard
    # fires before commit and the run aborts — the path never reaches main.
    [ -x "$REAL_SCRIPT_DIR/surgical-fast-path.sh" ] || skip "fast-path not present"

    # After implement, delta includes an out-of-scope pipeline path.
    export MOCK_GIT_POST_IMPL_FILES=" M .claude/scripts/orchestrate.sh
 M src/things.test.ts"

    run "$REAL_SCRIPT_DIR/surgical-fast-path.sh"

    [ "$status" -ne 0 ]
    assert_json_field "$STATUS_FILE" '.state' 'failed'
    err=$(jq -r '.error // ""' "$STATUS_FILE")
    # Error name must signal scope rejection (exact string owned by the impl).
    [[ "$err" == *scope* || "$err" == *pipeline* || "$err" == *out_of_scope* || "$err" == *staged_path* ]]
    # fast_path_pr must NOT be completed — commit was aborted.
    pr_status=$(jq -r '.stages.fast_path_pr.status // "pending"' "$STATUS_FILE")
    [[ "$pr_status" != "completed" ]]
}
