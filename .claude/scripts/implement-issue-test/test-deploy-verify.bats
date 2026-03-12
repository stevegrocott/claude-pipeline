#!/usr/bin/env bats
#
# test-deploy-verify.bats
# Tests for the deploy-verify stage:
#   - should_run_deploy_verify label detection gating
#   - health polling logic
#   - stage skip when DEPLOY_VERIFY_CMD is empty
#   - timeout handling (health URL poll)
#   - schema output format (implement-issue-deploy-verify.json)
#

load 'helpers/test-helper.bash'

setup() {
    setup_test_env
    install_mocks

    export ISSUE_NUMBER=99
    export BASE_BRANCH=main
    export STATUS_FILE="$TEST_TMP/status.json"
    export LOG_BASE="$TEST_TMP/logs/test"
    export LOG_FILE="$LOG_BASE/orchestrator.log"
    export STAGE_COUNTER=0
    export _CONSECUTIVE_TIMEOUTS=0
    export SCHEMA_DIR="$TEST_TMP/schemas"
    export TRACKER="github"

    mkdir -p "$LOG_BASE/stages" "$LOG_BASE/context"
    mkdir -p "$SCHEMA_DIR"

    source_orchestrator_functions
}

teardown() {
    teardown_test_env
}

# =============================================================================
# SECTION 1: STAGE SKIP WHEN DEPLOY_VERIFY_CMD IS EMPTY (gate a)
# =============================================================================

@test "should_run_deploy_verify returns 1 when DEPLOY_VERIFY_CMD is empty" {
    DEPLOY_VERIFY_CMD=""
    run should_run_deploy_verify "$ISSUE_NUMBER"
    [ "$status" -eq 1 ]
}

@test "should_run_deploy_verify returns 1 when DEPLOY_VERIFY_CMD is unset" {
    unset DEPLOY_VERIFY_CMD
    run should_run_deploy_verify "$ISSUE_NUMBER"
    [ "$status" -eq 1 ]
}

@test "should_run_deploy_verify returns 1 when DEPLOY_VERIFY_CMD set but no label or body section" {
    export DEPLOY_VERIFY_CMD="./scripts/deploy-test.sh"

    # gh returns no labels (mock returns "Mock gh: ..." which won't match)
    # No issue body file → both label check and body check fail
    run should_run_deploy_verify "$ISSUE_NUMBER"
    [ "$status" -eq 1 ]
}

# =============================================================================
# SECTION 2: LABEL DETECTION GATING (gate b — labels)
# =============================================================================

@test "should_run_deploy_verify returns 0 when env:test label is present" {
    export DEPLOY_VERIFY_CMD="./scripts/deploy-test.sh"
    export TRACKER="github"

    # Override gh to return env:test label
    gh() {
        printf 'env:test\n'
    }
    export -f gh

    run should_run_deploy_verify "$ISSUE_NUMBER"
    [ "$status" -eq 0 ]
}

@test "should_run_deploy_verify returns 0 when env:nas label is present" {
    export DEPLOY_VERIFY_CMD="./scripts/deploy-nas.sh"
    export TRACKER="github"

    gh() {
        printf 'env:nas\n'
    }
    export -f gh

    run should_run_deploy_verify "$ISSUE_NUMBER"
    [ "$status" -eq 0 ]
}

@test "should_run_deploy_verify returns 0 when env:staging label is present" {
    export DEPLOY_VERIFY_CMD="./scripts/deploy-staging.sh"
    export TRACKER="github"

    gh() {
        printf 'env:staging\n'
    }
    export -f gh

    run should_run_deploy_verify "$ISSUE_NUMBER"
    [ "$status" -eq 0 ]
}

@test "should_run_deploy_verify returns 1 when unrelated labels are present" {
    export DEPLOY_VERIFY_CMD="./scripts/deploy-test.sh"
    export TRACKER="github"

    # Labels that don't match env:test|nas|staging
    gh() {
        printf 'bug\nenhancement\nenv:production\n'
    }
    export -f gh

    run should_run_deploy_verify "$ISSUE_NUMBER"
    [ "$status" -eq 1 ]
}

@test "should_run_deploy_verify returns 1 when env:production label (not in gate list)" {
    export DEPLOY_VERIFY_CMD="./scripts/deploy.sh"
    export TRACKER="github"

    gh() {
        printf 'env:production\n'
    }
    export -f gh

    run should_run_deploy_verify "$ISSUE_NUMBER"
    [ "$status" -eq 1 ]
}

# =============================================================================
# SECTION 3: ISSUE BODY SECTION DETECTION (gate b — body fallback)
# =============================================================================

@test "should_run_deploy_verify returns 0 when issue body has Deploy Verification section" {
    export DEPLOY_VERIFY_CMD="./scripts/deploy-test.sh"
    export TRACKER="github"

    # gh returns no matching labels
    gh() {
        printf 'bug\n'
    }
    export -f gh

    # Create issue body with ## Deploy Verification section
    local issue_body_file="$LOG_BASE/context/issue-body.md"
    cat > "$issue_body_file" << 'EOF'
## Acceptance Criteria
- Feature works

## Deploy Verification
- Check that health endpoint returns 200
- Verify the feature is live
EOF

    run should_run_deploy_verify "$ISSUE_NUMBER"
    [ "$status" -eq 0 ]
}

@test "should_run_deploy_verify returns 1 when issue body lacks Deploy Verification section" {
    export DEPLOY_VERIFY_CMD="./scripts/deploy-test.sh"
    export TRACKER="github"

    gh() {
        printf 'bug\n'
    }
    export -f gh

    local issue_body_file="$LOG_BASE/context/issue-body.md"
    cat > "$issue_body_file" << 'EOF'
## Acceptance Criteria
- Feature works

## Notes
- No deploy section here
EOF

    run should_run_deploy_verify "$ISSUE_NUMBER"
    [ "$status" -eq 1 ]
}

@test "should_run_deploy_verify returns 1 when no issue body file and no labels" {
    export DEPLOY_VERIFY_CMD="./scripts/deploy-test.sh"
    export TRACKER="github"

    gh() {
        printf ''
    }
    export -f gh

    # Ensure no issue body file
    rm -f "$LOG_BASE/context/issue-body.md"

    run should_run_deploy_verify "$ISSUE_NUMBER"
    [ "$status" -eq 1 ]
}

@test "should_run_deploy_verify prefers label check over body (label match with no body file)" {
    export DEPLOY_VERIFY_CMD="./scripts/deploy-test.sh"
    export TRACKER="github"

    gh() {
        printf 'env:test\n'
    }
    export -f gh

    # No body file — should still return 0 due to label
    rm -f "$LOG_BASE/context/issue-body.md"

    run should_run_deploy_verify "$ISSUE_NUMBER"
    [ "$status" -eq 0 ]
}

# =============================================================================
# SECTION 4: SCHEMA OUTPUT FORMAT
# =============================================================================

@test "deploy-verify schema file exists" {
    [[ -f "$SCRIPT_DIR/schemas/implement-issue-deploy-verify.json" ]]
}

@test "deploy-verify schema is valid JSON" {
    run jq '.' "$SCRIPT_DIR/schemas/implement-issue-deploy-verify.json"
    [ "$status" -eq 0 ]
}

@test "deploy-verify schema requires status field" {
    local required
    required=$(jq -r '.required[]' "$SCRIPT_DIR/schemas/implement-issue-deploy-verify.json")
    printf '%s\n' "$required" | grep -q '^status$'
}

@test "deploy-verify schema requires deployment_target field" {
    local required
    required=$(jq -r '.required[]' "$SCRIPT_DIR/schemas/implement-issue-deploy-verify.json")
    printf '%s\n' "$required" | grep -q '^deployment_target$'
}

@test "deploy-verify schema requires health_status field" {
    local required
    required=$(jq -r '.required[]' "$SCRIPT_DIR/schemas/implement-issue-deploy-verify.json")
    printf '%s\n' "$required" | grep -q '^health_status$'
}

@test "deploy-verify schema requires summary field" {
    local required
    required=$(jq -r '.required[]' "$SCRIPT_DIR/schemas/implement-issue-deploy-verify.json")
    printf '%s\n' "$required" | grep -q '^summary$'
}

@test "deploy-verify schema status enum includes success" {
    local enum_vals
    enum_vals=$(jq -r '.properties.status.enum[]' "$SCRIPT_DIR/schemas/implement-issue-deploy-verify.json")
    printf '%s\n' "$enum_vals" | grep -q '^success$'
}

@test "deploy-verify schema status enum includes error" {
    local enum_vals
    enum_vals=$(jq -r '.properties.status.enum[]' "$SCRIPT_DIR/schemas/implement-issue-deploy-verify.json")
    printf '%s\n' "$enum_vals" | grep -q '^error$'
}

@test "deploy-verify schema status enum includes partial" {
    local enum_vals
    enum_vals=$(jq -r '.properties.status.enum[]' "$SCRIPT_DIR/schemas/implement-issue-deploy-verify.json")
    printf '%s\n' "$enum_vals" | grep -q '^partial$'
}

@test "deploy-verify schema health_status enum includes healthy" {
    local enum_vals
    enum_vals=$(jq -r '.properties.health_status.enum[]' "$SCRIPT_DIR/schemas/implement-issue-deploy-verify.json")
    printf '%s\n' "$enum_vals" | grep -q '^healthy$'
}

@test "deploy-verify schema health_status enum includes degraded" {
    local enum_vals
    enum_vals=$(jq -r '.properties.health_status.enum[]' "$SCRIPT_DIR/schemas/implement-issue-deploy-verify.json")
    printf '%s\n' "$enum_vals" | grep -q '^degraded$'
}

@test "deploy-verify schema health_status enum includes failed" {
    local enum_vals
    enum_vals=$(jq -r '.properties.health_status.enum[]' "$SCRIPT_DIR/schemas/implement-issue-deploy-verify.json")
    printf '%s\n' "$enum_vals" | grep -q '^failed$'
}

@test "deploy-verify schema health_status enum includes unknown" {
    local enum_vals
    enum_vals=$(jq -r '.properties.health_status.enum[]' "$SCRIPT_DIR/schemas/implement-issue-deploy-verify.json")
    printf '%s\n' "$enum_vals" | grep -q '^unknown$'
}

@test "deploy-verify schema has verification_results object property" {
    local type
    type=$(jq -r '.properties.verification_results.type' "$SCRIPT_DIR/schemas/implement-issue-deploy-verify.json")
    [ "$type" = "object" ]
}

@test "deploy-verify schema has issues array property" {
    local type
    type=$(jq -r '.properties.issues.type' "$SCRIPT_DIR/schemas/implement-issue-deploy-verify.json")
    [ "$type" = "array" ]
}

# =============================================================================
# SECTION 5: MODEL AND TIER CONFIGURATION
# =============================================================================

@test "deploy-verify stage maps to light tier (haiku)" {
    run bash -c "source '$SCRIPT_DIR/model-config.sh' && resolve_model 'deploy-verify'"
    [ "$status" -eq 0 ]
    [ "$output" = "haiku" ]
}

@test "deploy-verify stage with suffix maps to light tier" {
    run bash -c "source '$SCRIPT_DIR/model-config.sh' && resolve_model 'deploy-verify-iter-1'"
    [ "$status" -eq 0 ]
    [ "$output" = "haiku" ]
}

@test "deploy-verify complexity hint ignored (light tier always haiku)" {
    # deploy-verify is light — complexity hints must not override it
    run bash -c "source '$SCRIPT_DIR/model-config.sh' && resolve_model 'deploy-verify' 'L'"
    [ "$status" -eq 0 ]
    [ "$output" = "haiku" ]
}

# =============================================================================
# SECTION 6: STAGE TIMEOUT VALUE
# =============================================================================

@test "deploy-verify stage gets 900s timeout" {
    local t
    t=$(get_stage_timeout "deploy-verify")
    [ "$t" = "900" ]
}

@test "deploy-verify with suffix gets 900s timeout" {
    local t
    t=$(get_stage_timeout "deploy-verify-iter-1")
    [ "$t" = "900" ]
}

# =============================================================================
# SECTION 7: HEALTH POLLING LOGIC
# =============================================================================

@test "health poll succeeds immediately on first 2xx response" {
    curl() { printf '200'; }
    export -f curl
    sleep() { :; }
    export -f sleep

    run poll_health_url "http://localhost:8080/health" 90 10
    [ "$status" -eq 0 ]
}

@test "health poll continues on non-2xx responses" {
    local count_file="$TEST_TMP/curl-count.txt"
    printf '0' > "$count_file"
    # Return 503 twice then 200
    curl() {
        local n
        n=$(cat "$count_file")
        n=$((n + 1))
        printf '%s' "$n" > "$count_file"
        if (( n < 3 )); then printf '503'; else printf '200'; fi
    }
    export -f curl
    export count_file
    sleep() { :; }
    export -f sleep

    run poll_health_url "http://localhost:8080/health" 90 10
    [ "$status" -eq 0 ]
    [ "$(cat "$count_file")" -eq 3 ]
}

@test "health poll returns failure after max retries" {
    curl() { printf '503'; }
    export -f curl
    sleep() { :; }
    export -f sleep

    # Use max_retries=3 for speed
    run poll_health_url "http://localhost:8080/health" 3 10
    [ "$status" -eq 1 ]
}

@test "health poll skipped when URL is empty (returns success)" {
    local count_file="$TEST_TMP/curl-empty.txt"
    printf '0' > "$count_file"
    curl() {
        local n; n=$(cat "$count_file"); printf '%s' "$((n + 1))" > "$count_file"
        printf '200'
    }
    export -f curl
    export count_file
    sleep() { :; }
    export -f sleep

    run poll_health_url "" 90 10
    [ "$status" -eq 0 ]
    [ "$(cat "$count_file")" -eq 0 ]
}

@test "health poll accepts 201 as healthy (2xx range)" {
    curl() { printf '201'; }
    export -f curl
    sleep() { :; }
    export -f sleep

    run poll_health_url "http://localhost:8080/health" 90 10
    [ "$status" -eq 0 ]
}

@test "health poll treats curl failure (000) as not healthy, retries until 2xx" {
    local count_file="$TEST_TMP/curl-count2.txt"
    printf '0' > "$count_file"
    curl() {
        local n
        n=$(cat "$count_file")
        n=$((n + 1))
        printf '%s' "$n" > "$count_file"
        # First call simulates connection failure (000); second returns 200
        if (( n == 1 )); then printf '000'; else printf '200'; fi
    }
    export -f curl
    export count_file
    sleep() { :; }
    export -f sleep

    run poll_health_url "http://localhost:8080/health" 90 10
    [ "$status" -eq 0 ]
    [ "$(cat "$count_file")" -eq 2 ]
}

# =============================================================================
# SECTION 8: run_stage integration for deploy-verify schema
# =============================================================================

@test "run_stage accepts deploy-verify schema and extracts status field" {
    # Mock claude/timeout to return a valid deploy-verify structured output
    timeout() {
        shift  # skip timeout value
        echo '{"result":"deploy complete","structured_output":{"status":"success","deployment_target":"staging","health_status":"healthy","summary":"All checks passed"}}'
    }
    export -f timeout

    local result
    result=$(run_stage "deploy-verify" "verify prompt" "implement-issue-deploy-verify.json" | grep '^{')
    [ -n "$result" ] || fail "run_stage returned no JSON output"

    local status_val
    status_val=$(printf '%s' "$result" | jq -r '.status')
    [ "$status_val" = "success" ] || \
        fail "Expected status=success, got: $status_val (full output: $result)"
}

@test "run_stage extracts health_status from deploy-verify output" {
    timeout() {
        shift
        echo '{"result":"deploy complete","structured_output":{"status":"success","deployment_target":"staging","health_status":"healthy","summary":"All checks passed"}}'
    }
    export -f timeout

    local result
    result=$(run_stage "deploy-verify" "verify prompt" "implement-issue-deploy-verify.json" | grep '^{')
    [ -n "$result" ] || fail "run_stage returned no JSON output"

    local health_val
    health_val=$(printf '%s' "$result" | jq -r '.health_status')
    [ "$health_val" = "healthy" ] || \
        fail "Expected health_status=healthy, got: $health_val (full output: $result)"
}

@test "run_stage extracts deployment_target from deploy-verify output" {
    timeout() {
        shift
        echo '{"result":"deploy complete","structured_output":{"status":"success","deployment_target":"staging","health_status":"healthy","summary":"All checks passed"}}'
    }
    export -f timeout

    local result
    result=$(run_stage "deploy-verify" "verify prompt" "implement-issue-deploy-verify.json" | grep '^{')
    [ -n "$result" ] || fail "run_stage returned no JSON output"

    local target_val
    target_val=$(printf '%s' "$result" | jq -r '.deployment_target')
    [ "$target_val" = "staging" ] || \
        fail "Expected deployment_target=staging, got: $target_val (full output: $result)"
}

@test "run_stage handles partial status in deploy-verify output" {
    timeout() {
        shift
        echo '{"result":"partial deploy","structured_output":{"status":"partial","deployment_target":"test","health_status":"degraded","summary":"Some checks failed"}}'
    }
    export -f timeout

    local result
    result=$(run_stage "deploy-verify" "verify prompt" "implement-issue-deploy-verify.json" | grep '^{')
    [ -n "$result" ] || fail "run_stage returned no JSON output"

    local status_val
    status_val=$(printf '%s' "$result" | jq -r '.status')
    [ "$status_val" = "partial" ] || \
        fail "Expected status=partial, got: $status_val (full output: $result)"
}
