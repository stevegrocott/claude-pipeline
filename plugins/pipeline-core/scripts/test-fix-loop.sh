#!/usr/bin/env bash
#
# test-fix-loop.sh
# Runs Playwright E2E tests, detects failures, creates bug issues via Claude,
# fixes them via implement-issue-orchestrator.sh, and loops until all pass.
#
# Usage:
#   ./.claude/scripts/test-fix-loop.sh
#   ./.claude/scripts/test-fix-loop.sh --test-file tests/e2e/molesworth-farmer-journey.spec.ts
#   ./.claude/scripts/test-fix-loop.sh --max-iterations 5 --max-attempts-per-ac 2
#   ./.claude/scripts/test-fix-loop.sh --branch feature/issue-679
#
# Outputs:
#   - logs/test-fix-loop/<timestamp>/status.json: Real-time progress
#   - logs/test-fix-loop/<timestamp>/stages/: Per-iteration logs
#

set -uo pipefail  # Note: not -e, we handle errors explicitly

# =============================================================================
# CONFIGURATION
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config/platform.sh"
source "$SCRIPT_DIR/model-config.sh"

# Limits
MAX_ITERATIONS="${MAX_ITERATIONS:-10}"
MAX_ATTEMPTS_PER_AC="${MAX_ATTEMPTS_PER_AC:-3}"
RATE_LIMIT_BUFFER=60
RATE_LIMIT_DEFAULT_WAIT=3600

# Defaults
TEST_FILE="tests/e2e/molesworth-farmer-journey.spec.ts"
BASE_BRANCH="main"
PLAYWRIGHT_TIMEOUT=300  # 5 min for playwright run
CLAUDE_STAGE_TIMEOUT=1800  # 30 min for claude explore/fix stages

# =============================================================================
# PORTABLE TIMEOUT (macOS does not ship GNU timeout)
# =============================================================================

if ! command -v timeout &>/dev/null; then
    timeout() {
        local duration="$1"; shift
        perl -e '
            use POSIX ":sys_wait_h";
            alarm shift @ARGV;
            $SIG{ALRM} = sub { kill 15, $pid; waitpid($pid, 0); exit 124 };
            $pid = fork // die "fork: $!";
            if ($pid == 0) { exec @ARGV; die "exec: $!" }
            waitpid($pid, 0);
            exit ($? >> 8);
        ' "$duration" "$@"
    }
fi

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --test-file <path>         Playwright test file (default: $TEST_FILE)
  --branch <name>            Base branch for fix PRs (default: $BASE_BRANCH)
  --max-iterations <n>       Max total iterations (default: $MAX_ITERATIONS)
  --max-attempts-per-ac <n>  Max fix attempts per AC (default: $MAX_ATTEMPTS_PER_AC)
  --help                     Show this help

Environment overrides:
  MAX_ITERATIONS             Same as --max-iterations
  MAX_ATTEMPTS_PER_AC        Same as --max-attempts-per-ac
EOF
    exit 3
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --test-file)
            [[ -n "${2:-}" ]] || { echo "ERROR: --test-file requires a value" >&2; exit 3; }
            TEST_FILE="$2"
            shift 2
            ;;
        --branch)
            [[ -n "${2:-}" ]] || { echo "ERROR: --branch requires a value" >&2; exit 3; }
            BASE_BRANCH="$2"
            shift 2
            ;;
        --max-iterations)
            [[ -n "${2:-}" ]] || { echo "ERROR: --max-iterations requires a value" >&2; exit 3; }
            MAX_ITERATIONS="$2"
            shift 2
            ;;
        --max-attempts-per-ac)
            [[ -n "${2:-}" ]] || { echo "ERROR: --max-attempts-per-ac requires a value" >&2; exit 3; }
            MAX_ATTEMPTS_PER_AC="$2"
            shift 2
            ;;
        --help|-h)
            usage
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            ;;
    esac
done

# Validate test file exists
if [[ ! -f "$TEST_FILE" ]]; then
    echo "ERROR: Test file not found: $TEST_FILE" >&2
    exit 1
fi

# =============================================================================
# LOGGING
# =============================================================================

LOG_BASE="logs/test-fix-loop/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOG_BASE/stages"

LOG_FILE="$LOG_BASE/orchestrator.log"
STATUS_FILE="$LOG_BASE/status.json"
STAGE_COUNTER=0

log() {
    local msg="[$(date -Iseconds)] $*"
    printf '%s\n' "$msg" >> "$LOG_FILE"
    printf '%s\n' "$msg" >&2
}

log_error() {
    local msg="[$(date -Iseconds)] ERROR: $*"
    printf '%s\n' "$msg" >> "$LOG_FILE"
    printf '%s\n' "$msg" >&2
}

next_stage_log() {
    local stage_name="$1"
    STAGE_COUNTER=$((STAGE_COUNTER + 1))
    printf "%02d-%s.log" "$STAGE_COUNTER" "$stage_name"
}

# =============================================================================
# STATUS FILE MANAGEMENT
# =============================================================================

init_status() {
    jq -n \
        --argjson iteration 0 \
        --argjson total_acs 0 \
        --argjson passed_acs 0 \
        --arg current_failure "" \
        --argjson issues_created '[]' \
        --argjson issues_fixed '[]' \
        --arg state "initializing" \
        --arg test_file "$TEST_FILE" \
        --arg log_dir "$LOG_BASE" \
        '{
            iteration: $iteration,
            total_acs: $total_acs,
            passed_acs: $passed_acs,
            current_failure: $current_failure,
            issues_created: $issues_created,
            issues_fixed: $issues_fixed,
            state: $state,
            test_file: $test_file,
            log_dir: $log_dir,
            ac_attempts: {},
            last_update: (now | todate)
        }' > "$STATUS_FILE"
    log "Initialized status: $STATUS_FILE"
}

update_status() {
    local field="$1"
    local value="$2"
    local value_type="${3:-string}"  # string, number, array, raw

    case "$value_type" in
        string)
            jq --arg f "$field" --arg v "$value" \
                '.[$f] = $v | .last_update = (now | todate)' \
                "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
            ;;
        number)
            jq --arg f "$field" --argjson v "$value" \
                '.[$f] = $v | .last_update = (now | todate)' \
                "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
            ;;
        raw)
            jq --arg f "$field" --argjson v "$value" \
                '.[$f] = $v | .last_update = (now | todate)' \
                "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
            ;;
    esac
}

increment_ac_attempts() {
    local ac_key="$1"
    jq --arg k "$ac_key" \
        '.ac_attempts[$k] = ((.ac_attempts[$k] // 0) + 1) | .last_update = (now | todate)' \
        "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
}

get_ac_attempts() {
    local ac_key="$1"
    jq -r --arg k "$ac_key" '.ac_attempts[$k] // 0' "$STATUS_FILE"
}

add_issue_created() {
    local issue_number="$1"
    jq --arg i "$issue_number" \
        '.issues_created += [$i] | .last_update = (now | todate)' \
        "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
}

add_issue_fixed() {
    local issue_number="$1"
    jq --arg i "$issue_number" \
        '.issues_fixed += [$i] | .last_update = (now | todate)' \
        "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
}

# =============================================================================
# RATE LIMIT DETECTION (reused from implement-issue-orchestrator.sh)
# =============================================================================

detect_rate_limit() {
    local output="$1"

    local status
    status=$(printf '%s' "$output" | jq -r '.structured_output.status // empty' 2>/dev/null)

    if [[ "$status" == "success" ]]; then
        return 1
    fi

    if [[ "$status" == "rate_limit" ]]; then
        return 0
    fi

    local is_error
    is_error=$(printf '%s' "$output" | jq -r '.is_error // false' 2>/dev/null)

    if [[ "$is_error" != "true" ]]; then
        return 1
    fi

    local result
    result=$(printf '%s' "$output" | jq -r '.result // empty' 2>/dev/null)
    if printf '%s' "$result" | grep -qiE 'rate.limit|429|too many requests|quota.exceeded'; then
        return 0
    fi

    return 1
}

extract_wait_time() {
    local output="$1"
    local result
    result=$(printf '%s' "$output" | jq -r '.result // empty' 2>/dev/null)
    local search_text="$result $output"

    local retry_after
    retry_after=$(printf '%s' "$search_text" | grep -oiE 'retry.after[^0-9]*([0-9]+)' | grep -oE '[0-9]+' | head -1)
    if [[ -n "$retry_after" ]] && (( retry_after > 0 )); then
        printf '%s\n' "$retry_after"
        return
    fi

    local wait_mins
    wait_mins=$(printf '%s' "$search_text" | grep -oiE 'wait[^0-9]*([0-9]+)[^0-9]*min' | grep -oE '[0-9]+' | head -1)
    if [[ -n "$wait_mins" ]] && (( wait_mins > 0 )); then
        printf '%s\n' "$((wait_mins * 60))"
        return
    fi

    printf '%s\n' "$RATE_LIMIT_DEFAULT_WAIT"
}

handle_rate_limit() {
    local output="$1"
    local wait_time
    wait_time=$(extract_wait_time "$output")
    wait_time=$((wait_time + RATE_LIMIT_BUFFER))

    local resume_at
    resume_at=$(date -Iseconds -d "+${wait_time} seconds" 2>/dev/null \
        || date -v+${wait_time}S -Iseconds 2>/dev/null \
        || echo "unknown")

    log "Rate limit hit. Waiting ${wait_time}s until $resume_at"
    update_status "state" "rate_limited"
    sleep "$wait_time"
    update_status "state" "running"
}

# =============================================================================
# PLAYWRIGHT TEST RUNNER
# =============================================================================

run_playwright_tests() {
    local iteration="$1"
    local stage_log="$LOG_BASE/stages/$(next_stage_log "playwright-iter-$iteration")"
    local json_output_file="$LOG_BASE/stages/playwright-iter-${iteration}-results.json"

    log "Running Playwright tests (iteration $iteration): $TEST_FILE"

    local exit_code=0
    local raw_output_file="${json_output_file}.raw"
    timeout "$PLAYWRIGHT_TIMEOUT" npx playwright test "$TEST_FILE" \
        --reporter=json \
        > "$raw_output_file" 2>"$stage_log" || exit_code=$?

    # Playwright JSON reporter mixes global setup/teardown stdout with JSON.
    # Extract only the JSON portion (starts with first '{' on a line).
    if [[ -f "$raw_output_file" ]]; then
        sed -n '/^{/,$p' "$raw_output_file" > "$json_output_file"
        # If sed produced empty output, the JSON may start after cleanup output
        if [[ ! -s "$json_output_file" ]]; then
            # Try extracting from first line containing opening brace
            grep -n '{' "$raw_output_file" | head -1 | cut -d: -f1 | while read -r line_num; do
                tail -n +"$line_num" "$raw_output_file" > "$json_output_file"
            done
        fi
    fi

    if (( exit_code == 124 )); then
        log_error "Playwright timed out after ${PLAYWRIGHT_TIMEOUT}s"
        return 124
    fi

    log "Playwright exit code: $exit_code"
    printf '%s' "$json_output_file"
    return "$exit_code"
}

# =============================================================================
# PARSE PLAYWRIGHT JSON RESULTS
# =============================================================================

parse_test_results() {
    local json_file="$1"

    if [[ ! -f "$json_file" ]]; then
        log_error "Playwright JSON output not found: $json_file"
        echo '{"total":0,"passed":0,"failed":0,"failures":[]}'
        return 1
    fi

    # Extract test counts and first failure details from JSON reporter output
    # Playwright JSON reporter structure: { suites: [ { specs: [ { tests: [ { results: [...] } ] } ] } ] }
    jq -c '
        # Flatten all test results
        [.suites[]?.specs[]? | {
            title: .title,
            test_id: .id,
            file: .file,
            results: [.tests[]?.results[]?],
            ok: .ok
        }] as $all_tests |

        # Count totals
        ($all_tests | length) as $total |
        [$all_tests[] | select(.ok == true)] | length as $passed |
        [$all_tests[] | select(.ok != true)] as $failed_tests |
        ($failed_tests | length) as $failed |

        # Extract first failure details
        (if ($failed > 0) then
            $failed_tests[0] | {
                test_name: .title,
                file: .file,
                error_message: ([.results[]? | .error?.message // empty] | first // "unknown error"),
                error_snippet: ([.results[]? | .error?.snippet // empty] | first // ""),
                screenshot: ([.results[]? | .attachments[]? | select(.name == "screenshot") | .path // empty] | first // "")
            }
        else
            null
        end) as $first_failure |

        {
            total: $total,
            passed: $passed,
            failed: $failed,
            first_failure: $first_failure,
            failed_tests: [$failed_tests[] | .title]
        }
    ' "$json_file" 2>/dev/null || {
        log_error "Failed to parse Playwright JSON output"
        echo '{"total":0,"passed":0,"failed":0,"failures":[]}'
        return 1
    }
}

# =============================================================================
# CREATE BUG ISSUE VIA CLAUDE
# =============================================================================

create_bug_issue() {
    local test_name="$1"
    local error_message="$2"
    local screenshot_path="$3"
    local test_file="$4"
    local iteration="$5"

    local stage_log="$LOG_BASE/stages/$(next_stage_log "create-issue-iter-$iteration")"

    # Build the explore prompt with failure context
    local screenshot_context=""
    if [[ -n "$screenshot_path" && -f "$screenshot_path" ]]; then
        screenshot_context="Screenshot of failure: $screenshot_path"
    fi

    local prompt
    prompt=$(cat <<PROMPT_EOF
/explore

## Bug Report: E2E Test Failure

**Failing test:** \`$test_name\`
**Test file:** \`$test_file\`
**Error message:**
\`\`\`
$error_message
\`\`\`
$screenshot_context

## Context
This test failure was detected during automated E2E testing of the Molesworth farmer journey.
The test is part of the acceptance criteria validation for the farmer workflow.

## Instructions
1. Investigate the root cause of this test failure
2. Identify the affected files and components
3. Create a GitHub issue with:
   - Clear description of the bug
   - Steps to reproduce (the failing test)
   - Affected files
   - Suggested fix approach
   - Label: bug
4. Output the created issue number at the end in the format: ISSUE_NUMBER=<number>
PROMPT_EOF
)

    log "Creating bug issue for failing test: $test_name"

    local output
    local exit_code=0

    output=$(timeout "$CLAUDE_STAGE_TIMEOUT" env -u CLAUDECODE "$CLAUDE_CLI" -p "$prompt" \
        --model "$(resolve_model "implement" "")" \
        --dangerously-skip-permissions \
        --output-format json \
        2>&1) || exit_code=$?

    printf '%s\n' "=== create-issue output ===" >> "$stage_log"
    printf '%s\n' "$output" >> "$stage_log"
    printf '%s\n' "=== exit code: $exit_code ===" >> "$stage_log"

    if (( exit_code == 124 )); then
        log_error "Claude timed out creating issue"
        return 1
    fi

    # Check rate limit
    if detect_rate_limit "$output"; then
        handle_rate_limit "$output"
        # Retry once
        output=$(timeout "$CLAUDE_STAGE_TIMEOUT" env -u CLAUDECODE "$CLAUDE_CLI" -p "$prompt" \
            --model "$(resolve_model "implement" "")" \
            --dangerously-skip-permissions \
            --output-format json \
            2>&1) || exit_code=$?

        printf '%s\n' "=== create-issue retry output ===" >> "$stage_log"
        printf '%s\n' "$output" >> "$stage_log"
    fi

    # Extract issue number from Claude output
    # Look for ISSUE_NUMBER=<digits> pattern in the result text
    local result_text
    result_text=$(printf '%s' "$output" | jq -r '.result // empty' 2>/dev/null)

    local issue_number
    issue_number=$(printf '%s' "$result_text" | grep -oE 'ISSUE_NUMBER=[0-9]+' | grep -oE '[0-9]+' | head -1)

    # Fallback: look for "gh issue create" output patterns like "#123" or "issue/123"
    if [[ -z "$issue_number" ]]; then
        issue_number=$(printf '%s' "$result_text" | grep -oE '#[0-9]+' | grep -oE '[0-9]+' | tail -1)
    fi

    # Fallback: look for github issue URL
    if [[ -z "$issue_number" ]]; then
        issue_number=$(printf '%s' "$result_text" | grep -oE 'issues/[0-9]+' | grep -oE '[0-9]+' | tail -1)
    fi

    if [[ -z "$issue_number" ]]; then
        log_error "Could not extract issue number from Claude output"
        return 1
    fi

    log "Created issue #$issue_number for: $test_name"
    printf '%s' "$issue_number"
}

# =============================================================================
# FIX BUG VIA IMPLEMENT-ISSUE-ORCHESTRATOR
# =============================================================================

fix_bug_issue() {
    local issue_number="$1"
    local iteration="$2"

    local stage_log="$LOG_BASE/stages/$(next_stage_log "fix-issue-$issue_number-iter-$iteration")"

    log "Fixing issue #$issue_number via implement-issue-orchestrator.sh"

    local exit_code=0
    timeout 3600 bash "$SCRIPT_DIR/implement-issue-orchestrator.sh" \
        --issue "$issue_number" \
        --branch "$BASE_BRANCH" \
        --quiet \
        > "$stage_log" 2>&1 || exit_code=$?

    log "implement-issue-orchestrator exit code: $exit_code (issue #$issue_number)"
    return "$exit_code"
}

# =============================================================================
# MAIN LOOP
# =============================================================================

main() {
    log "=== test-fix-loop started ==="
    log "Test file: $TEST_FILE"
    log "Base branch: $BASE_BRANCH"
    log "Max iterations: $MAX_ITERATIONS"
    log "Max attempts per AC: $MAX_ATTEMPTS_PER_AC"
    log "Log directory: $LOG_BASE"

    init_status
    update_status "state" "running"

    local iteration=0

    while (( iteration < MAX_ITERATIONS )); do
        iteration=$((iteration + 1))
        update_status "iteration" "$iteration" "number"

        log "--- Iteration $iteration/$MAX_ITERATIONS ---"

        # Step 1: Run Playwright tests
        local json_file
        local test_exit_code=0
        json_file=$(run_playwright_tests "$iteration") || test_exit_code=$?

        # Handle timeout separately — stdout is empty, no JSON to parse
        if (( test_exit_code == 124 )); then
            log_error "Playwright timed out — skipping fix attempt this iteration"
            update_status "state" "playwright_timeout"
            continue
        fi

        # If tests passed (exit code 0), we're done
        if (( test_exit_code == 0 )); then
            log "All tests passed on iteration $iteration!"

            # Parse final results for accurate counts
            local final_results
            final_results=$(parse_test_results "$json_file")
            local total passed
            total=$(printf '%s' "$final_results" | jq -r '.total')
            passed=$(printf '%s' "$final_results" | jq -r '.passed')

            update_status "total_acs" "$total" "number"
            update_status "passed_acs" "$passed" "number"
            update_status "current_failure" ""
            update_status "state" "completed"

            log "=== test-fix-loop completed: ALL TESTS PASS ==="
            log "Total: $total, Passed: $passed, Iterations: $iteration"
            return 0
        fi

        # Step 2: Parse failures
        local results
        results=$(parse_test_results "$json_file")

        local total passed failed
        total=$(printf '%s' "$results" | jq -r '.total')
        passed=$(printf '%s' "$results" | jq -r '.passed')
        failed=$(printf '%s' "$results" | jq -r '.failed')

        update_status "total_acs" "$total" "number"
        update_status "passed_acs" "$passed" "number"

        log "Results: $passed/$total passed, $failed failed"

        # Step 3: Get first failure details
        local test_name error_message screenshot_path
        test_name=$(printf '%s' "$results" | jq -r '.first_failure.test_name // "unknown"')
        error_message=$(printf '%s' "$results" | jq -r '.first_failure.error_message // "unknown error"')
        screenshot_path=$(printf '%s' "$results" | jq -r '.first_failure.screenshot // ""')

        update_status "current_failure" "$test_name"

        log "First failure: $test_name"

        # Step 4: Check per-AC attempt limit
        # Use test name as the AC key (sanitized)
        local ac_key
        ac_key=$(printf '%s' "$test_name" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-' | sed 's/-$//')
        increment_ac_attempts "$ac_key"

        local attempts
        attempts=$(get_ac_attempts "$ac_key")

        if (( attempts > MAX_ATTEMPTS_PER_AC )); then
            log_error "Max attempts ($MAX_ATTEMPTS_PER_AC) exceeded for AC: $test_name (attempts: $attempts)"
            update_status "state" "failed_max_attempts_per_ac"
            log "=== test-fix-loop stopped: MAX_ATTEMPTS_PER_AC exceeded for '$test_name' ==="
            return 1
        fi

        log "Attempt $attempts/$MAX_ATTEMPTS_PER_AC for: $test_name"

        # Step 5: Create bug issue via Claude
        local issue_number
        issue_number=$(create_bug_issue "$test_name" "$error_message" "$screenshot_path" "$TEST_FILE" "$iteration")

        if [[ -z "$issue_number" ]]; then
            log_error "Failed to create issue — skipping fix attempt"
            continue
        fi

        add_issue_created "$issue_number"

        # Step 6: Fix the bug via implement-issue-orchestrator
        local fix_exit_code=0
        fix_bug_issue "$issue_number" "$iteration" || fix_exit_code=$?

        if (( fix_exit_code == 0 )); then
            add_issue_fixed "$issue_number"
            log "Issue #$issue_number fixed successfully"
        else
            log_error "Failed to fix issue #$issue_number (exit code: $fix_exit_code)"
            # Continue to next iteration — re-running tests will show if progress was made
        fi

        # Step 7: Loop continues — next iteration will re-run tests
        log "Completed iteration $iteration, looping to re-test..."
    done

    # Exhausted max iterations
    log_error "Max iterations ($MAX_ITERATIONS) reached without all tests passing"
    update_status "state" "failed_max_iterations"

    # Final test run results
    local final_json final_results
    final_json=$(run_playwright_tests "final") || true
    if [[ -f "$final_json" ]]; then
        final_results=$(parse_test_results "$final_json")
        local final_passed final_total
        final_passed=$(printf '%s' "$final_results" | jq -r '.passed')
        final_total=$(printf '%s' "$final_results" | jq -r '.total')
        update_status "passed_acs" "$final_passed" "number"
        update_status "total_acs" "$final_total" "number"
        log "Final state: $final_passed/$final_total passed after $MAX_ITERATIONS iterations"
    fi

    log "=== test-fix-loop stopped: MAX_ITERATIONS reached ==="
    return 1
}

main "$@"
