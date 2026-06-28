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

@test "should_run_deploy_verify returns 0 when issue body has Deploy Verification section with non-empty Verification command" {
    export DEPLOY_VERIFY_CMD="./scripts/deploy-test.sh"
    export TRACKER="github"

    # gh returns no matching labels
    gh() {
        printf 'bug\n'
    }
    export -f gh

    # Create issue body with ## Deploy Verification section and
    # a non-empty **Verification command:** line
    local issue_body_file="$LOG_BASE/context/issue-body.md"
    cat > "$issue_body_file" << 'EOF'
## Acceptance Criteria
- Feature works

## Deploy Verification

**Verification command:** curl -s http://localhost:8080/health

- Check that health endpoint returns 200
- Verify the feature is live
EOF

    run should_run_deploy_verify "$ISSUE_NUMBER"
    [ "$status" -eq 0 ]
}

@test "should_run_deploy_verify returns 1 when Deploy Verification section has no Verification command line" {
    export DEPLOY_VERIFY_CMD="./scripts/deploy-test.sh"
    export TRACKER="github"

    gh() {
        printf 'bug\n'
    }
    export -f gh

    # Section exists but no **Verification command:** line at all
    local issue_body_file="$LOG_BASE/context/issue-body.md"
    cat > "$issue_body_file" << 'EOF'
## Acceptance Criteria
- Feature works

## Deploy Verification
- Check that health endpoint returns 200
- Verify the feature is live
EOF

    run should_run_deploy_verify "$ISSUE_NUMBER"
    [ "$status" -eq 1 ]
}

@test "should_run_deploy_verify returns 1 when Verification command line is empty" {
    export DEPLOY_VERIFY_CMD="./scripts/deploy-test.sh"
    export TRACKER="github"

    gh() {
        printf 'bug\n'
    }
    export -f gh

    # Section and heading exist but **Verification command:** has no value
    local issue_body_file="$LOG_BASE/context/issue-body.md"
    cat > "$issue_body_file" << 'EOF'
## Deploy Verification

**Verification command:**

- Check that health endpoint returns 200
EOF

    run should_run_deploy_verify "$ISSUE_NUMBER"
    [ "$status" -eq 1 ]
}

@test "should_run_deploy_verify returns 1 when Verification command line is whitespace only" {
    export DEPLOY_VERIFY_CMD="./scripts/deploy-test.sh"
    export TRACKER="github"

    gh() {
        printf 'bug\n'
    }
    export -f gh

    # **Verification command:**   (trailing spaces, no real value)
    local issue_body_file="$LOG_BASE/context/issue-body.md"
    printf '%s\n' \
        '## Deploy Verification' \
        '' \
        '**Verification command:**   ' \
        '' \
        '- Check health' \
        > "$LOG_BASE/context/issue-body.md"

    run should_run_deploy_verify "$ISSUE_NUMBER"
    [ "$status" -eq 1 ]
}

@test "should_run_deploy_verify ignores Verification command outside Deploy Verification section" {
    export DEPLOY_VERIFY_CMD="./scripts/deploy-test.sh"
    export TRACKER="github"

    gh() {
        printf 'bug\n'
    }
    export -f gh

    # **Verification command:** appears in a different section — must not trigger
    local issue_body_file="$LOG_BASE/context/issue-body.md"
    cat > "$issue_body_file" << 'EOF'
## Testing Notes

**Verification command:** curl http://other-section.example.com

## Deploy Verification

**Verification command:**
EOF

    run should_run_deploy_verify "$ISSUE_NUMBER"
    [ "$status" -eq 1 ]
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
# SECTION 4: FAST-PATH GATE
# =============================================================================

@test "should_run_deploy_verify returns 1 when route is fast-path" {
    export DEPLOY_VERIFY_CMD="./scripts/deploy-test.sh"

    # Write a status.json with route set to fast-path
    printf '{"route":"fast-path","state":"running"}\n' \
        > "$STATUS_FILE"

    gh() { printf 'env:test\n'; }
    export -f gh

    run should_run_deploy_verify "$ISSUE_NUMBER"
    [ "$status" -eq 1 ]
}

@test "should_run_deploy_verify is not blocked when route is full" {
    export DEPLOY_VERIFY_CMD="./scripts/deploy-test.sh"

    # Write a status.json with route set to full
    printf '{"route":"full","state":"running"}\n' \
        > "$STATUS_FILE"

    gh() { printf 'env:test\n'; }
    export -f gh

    run should_run_deploy_verify "$ISSUE_NUMBER"
    [ "$status" -eq 0 ]
}

@test "should_run_deploy_verify is not blocked when STATUS_FILE has no route" {
    export DEPLOY_VERIFY_CMD="./scripts/deploy-test.sh"

    # Write a status.json with no route field (defaults to full)
    printf '{"state":"running"}\n' > "$STATUS_FILE"

    gh() { printf 'env:test\n'; }
    export -f gh

    run should_run_deploy_verify "$ISSUE_NUMBER"
    [ "$status" -eq 0 ]
}

@test "should_run_deploy_verify fast-path gate wins over env:test label" {
    # Even with a qualifying label, fast-path must skip deploy-verify
    export DEPLOY_VERIFY_CMD="./scripts/deploy-test.sh"

    printf '{"route":"fast-path","state":"running"}\n' \
        > "$STATUS_FILE"

    gh() { printf 'env:staging\n'; }
    export -f gh

    run should_run_deploy_verify "$ISSUE_NUMBER"
    [ "$status" -eq 1 ]
}

# =============================================================================
# SECTION 5: SCHEMA OUTPUT FORMAT
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
# SECTION 6: MODEL AND TIER CONFIGURATION
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
# SECTION 7: STAGE TIMEOUT VALUE
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
# SECTION 8: HEALTH POLLING LOGIC
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
# SECTION 9: run_stage integration for deploy-verify schema
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

    # Structured fields nest under .output.*; only .status is lifted to top.
    local health_val
    health_val=$(printf '%s' "$result" | jq -r '.output.health_status')
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

    # Structured fields nest under .output.*; only .status is lifted to top.
    local target_val
    target_val=$(printf '%s' "$result" | jq -r '.output.deployment_target')
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

    # Top-level .status is the STAGE status; the deploy-verify status
    # ("partial") nests under .output.status.
    local status_val
    status_val=$(printf '%s' "$result" | jq -r '.output.status')
    [ "$status_val" = "partial" ] || \
        fail "Expected status=partial, got: $status_val (full output: $result)"
}

# =============================================================================
# SECTION 10: env:nas-premerge LABEL — deploy_verify must NOT trigger
# The env:nas-premerge label is handled by the NAS pre-merge notification
# path (a comment asking the human to trigger manually), not by
# should_run_deploy_verify.  These tests confirm the gate returns 1 so the
# post-merge deploy_verify stage is skipped for such issues.
# =============================================================================

@test "should_run_deploy_verify returns 1 for env:nas-premerge label" {
    export DEPLOY_VERIFY_CMD="./scripts/deploy-nas.sh"
    export TRACKER="github"

    gh() {
        printf 'env:nas-premerge\n'
    }
    export -f gh

    run should_run_deploy_verify "$ISSUE_NUMBER"
    [ "$status" -eq 1 ]
}

@test "should_run_deploy_verify returns 1 for env:nas-premerge with no body section" {
    # env:nas-premerge alone (no ## Deploy Verification body) must skip the
    # post-merge deploy_verify — the NAS pre-merge notification block handles
    # these issues by posting a comment pre-PR instead.
    export DEPLOY_VERIFY_CMD="./scripts/deploy-nas.sh"
    export TRACKER="github"

    gh() {
        printf 'env:nas-premerge\n'
    }
    export -f gh

    rm -f "$LOG_BASE/context/issue-body.md"

    run should_run_deploy_verify "$ISSUE_NUMBER"
    [ "$status" -eq 1 ]
}

@test "should_run_deploy_verify returns 0 for env:nas (regular NAS deploy, not premerge)" {
    export DEPLOY_VERIFY_CMD="./scripts/deploy-nas.sh"
    export TRACKER="github"

    gh() {
        printf 'env:nas\n'
    }
    export -f gh

    run should_run_deploy_verify "$ISSUE_NUMBER"
    [ "$status" -eq 0 ]
}

# =============================================================================
# SECTION 11: _select_deploy_cmd() TIER SELECTION
# =============================================================================

@test "_select_deploy_cmd: tier 1 — frontend-only changes return health-only cmd" {
    export DEPLOY_VERIFY_CMD="./scripts/deploy-nas.sh"
    export DEPLOY_LOCAL_CMD="./scripts/deploy-local.sh"
    export MIGRATION_PATH_PATTERNS="apps/backend/prisma/migrations/*|apps/backend/prisma/schema.prisma|.env*"

    local changed="src/components/Button.tsx
src/pages/index.tsx"

    run _select_deploy_cmd "$changed"
    [ "$status" -eq 0 ]
    [ "${lines[${#lines[@]}-1]}" = "./scripts/deploy-nas.sh --health-only" ]
}

@test "_select_deploy_cmd: tier 3 — backend logic-only changes return local deploy cmd" {
    export DEPLOY_VERIFY_CMD="./scripts/deploy-nas.sh"
    export DEPLOY_LOCAL_CMD="./scripts/deploy-local-backend.sh"
    export MIGRATION_PATH_PATTERNS="apps/backend/prisma/migrations/*|apps/backend/prisma/schema.prisma|.env*"

    local changed="apps/backend/src/services/user-service.ts
apps/backend/src/routes/user.ts"

    run _select_deploy_cmd "$changed"
    [ "$status" -eq 0 ]
    [ "${lines[${#lines[@]}-1]}" = "./scripts/deploy-local-backend.sh" ]
}

@test "_select_deploy_cmd: tier 3 — DEPLOY_LOCAL_CMD set, MIGRATION_PATH_PATTERNS unset, backend-only change returns local deploy cmd" {
    export DEPLOY_VERIFY_CMD="./scripts/deploy-nas.sh"
    export DEPLOY_LOCAL_CMD="./scripts/deploy-local-backend.sh"
    unset MIGRATION_PATH_PATTERNS

    local changed="apps/backend/src/services/user-service.ts
apps/backend/src/routes/user.ts"

    run _select_deploy_cmd "$changed"
    [ "$status" -eq 0 ]
    [ "${lines[${#lines[@]}-1]}" = "./scripts/deploy-local-backend.sh" ]
}

@test "_select_deploy_cmd: tier 2 — backend changes with migration file with DEPLOY_LOCAL_CMD set runs local then full deploy" {
    export DEPLOY_VERIFY_CMD="./scripts/deploy-nas.sh"
    export DEPLOY_LOCAL_CMD="./scripts/deploy-local-backend.sh"
    export MIGRATION_PATH_PATTERNS="apps/backend/prisma/migrations/*|apps/backend/prisma/schema.prisma|.env*"

    local changed="apps/backend/src/services/user-service.ts
apps/backend/prisma/migrations/20260101_add_users.sql"

    run _select_deploy_cmd "$changed"
    [ "$status" -eq 0 ]
    [ "${lines[${#lines[@]}-1]}" = "./scripts/deploy-local-backend.sh && ./scripts/deploy-nas.sh" ]
}

@test "_select_deploy_cmd: tier 2 — schema.prisma change with DEPLOY_LOCAL_CMD set runs local then full deploy (schema.prisma)" {
    export DEPLOY_VERIFY_CMD="./scripts/deploy-nas.sh"
    export DEPLOY_LOCAL_CMD="./scripts/deploy-local-backend.sh"
    export MIGRATION_PATH_PATTERNS="apps/backend/prisma/migrations/*|apps/backend/prisma/schema.prisma|.env*"

    local changed="apps/backend/src/services/crop.ts
apps/backend/prisma/schema.prisma"

    run _select_deploy_cmd "$changed"
    [ "$status" -eq 0 ]
    [ "${lines[${#lines[@]}-1]}" = "./scripts/deploy-local-backend.sh && ./scripts/deploy-nas.sh" ]
}

@test "_select_deploy_cmd: tier 2 — .env file change with DEPLOY_LOCAL_CMD set runs local then full deploy (.env)" {
    export DEPLOY_VERIFY_CMD="./scripts/deploy-nas.sh"
    export DEPLOY_LOCAL_CMD="./scripts/deploy-local-backend.sh"
    export MIGRATION_PATH_PATTERNS="apps/backend/prisma/migrations/*|apps/backend/prisma/schema.prisma|.env*"

    local changed="apps/backend/src/index.ts
.env.production"

    run _select_deploy_cmd "$changed"
    [ "$status" -eq 0 ]
    [ "${lines[${#lines[@]}-1]}" = "./scripts/deploy-local-backend.sh && ./scripts/deploy-nas.sh" ]
}

@test "_select_deploy_cmd: packages/ change treated as backend (tier 3 when no migrations)" {
    export DEPLOY_VERIFY_CMD="./scripts/deploy-nas.sh"
    export DEPLOY_LOCAL_CMD="./scripts/deploy-local-backend.sh"
    export MIGRATION_PATH_PATTERNS="apps/backend/prisma/migrations/*|apps/backend/prisma/schema.prisma|.env*"

    local changed="packages/shared/src/utils.ts
packages/api-client/src/client.ts"

    run _select_deploy_cmd "$changed"
    [ "$status" -eq 0 ]
    [ "${lines[${#lines[@]}-1]}" = "./scripts/deploy-local-backend.sh" ]
}

@test "_select_deploy_cmd: empty diff fail-safe returns full deploy cmd" {
    export DEPLOY_VERIFY_CMD="./scripts/deploy-nas.sh"
    export DEPLOY_LOCAL_CMD="./scripts/deploy-local-backend.sh"
    export MIGRATION_PATH_PATTERNS="apps/backend/prisma/migrations/*|apps/backend/prisma/schema.prisma|.env*"

    run _select_deploy_cmd ""
    [ "$status" -eq 0 ]
    [ "${lines[${#lines[@]}-1]}" = "./scripts/deploy-nas.sh" ]
}

@test "_select_deploy_cmd: unset DEPLOY_LOCAL_CMD — backend logic change falls through to full deploy" {
    export DEPLOY_VERIFY_CMD="./scripts/deploy-nas.sh"
    unset DEPLOY_LOCAL_CMD
    export MIGRATION_PATH_PATTERNS="apps/backend/prisma/migrations/*|apps/backend/prisma/schema.prisma|.env*"

    local changed="apps/backend/src/services/user-service.ts"

    run _select_deploy_cmd "$changed"
    [ "$status" -eq 0 ]
    [ "${lines[${#lines[@]}-1]}" = "./scripts/deploy-nas.sh" ]
}

@test "_select_deploy_cmd: empty DEPLOY_LOCAL_CMD — backend logic change falls through to full deploy" {
    export DEPLOY_VERIFY_CMD="./scripts/deploy-nas.sh"
    export DEPLOY_LOCAL_CMD=""
    export MIGRATION_PATH_PATTERNS="apps/backend/prisma/migrations/*|apps/backend/prisma/schema.prisma|.env*"

    local changed="apps/backend/src/services/user-service.ts"

    run _select_deploy_cmd "$changed"
    [ "$status" -eq 0 ]
    [ "${lines[${#lines[@]}-1]}" = "./scripts/deploy-nas.sh" ]
}

@test "_select_deploy_cmd: empty MIGRATION_PATH_PATTERNS — no migration downgrade (tier 3 local deploy)" {
    export DEPLOY_VERIFY_CMD="./scripts/deploy-nas.sh"
    export DEPLOY_LOCAL_CMD="./scripts/deploy-local-backend.sh"
    export MIGRATION_PATH_PATTERNS=""

    local changed="apps/backend/src/services/user-service.ts"

    run _select_deploy_cmd "$changed"
    [ "$status" -eq 0 ]
    # Empty MIGRATION_PATH_PATTERNS means has_migration stays false, so the
    # backend-logic change does NOT trigger the tier-2 "local && full" combo.
    # With DEPLOY_LOCAL_CMD set it lands on tier 3 (local deploy only).
    [ "${lines[${#lines[@]}-1]}" = "./scripts/deploy-local-backend.sh" ]
}

@test "_select_deploy_cmd: unset MIGRATION_PATH_PATTERNS — no migration downgrade (tier 3 local deploy)" {
    export DEPLOY_VERIFY_CMD="./scripts/deploy-nas.sh"
    export DEPLOY_LOCAL_CMD="./scripts/deploy-local-backend.sh"
    unset MIGRATION_PATH_PATTERNS

    local changed="apps/backend/src/services/user-service.ts"

    run _select_deploy_cmd "$changed"
    [ "$status" -eq 0 ]
    # Unset MIGRATION_PATH_PATTERNS means has_migration stays false, so the
    # backend-logic change does NOT trigger the tier-2 "local && full" combo.
    # With DEPLOY_LOCAL_CMD set it lands on tier 3 (local deploy only).
    [ "${lines[${#lines[@]}-1]}" = "./scripts/deploy-local-backend.sh" ]
}

# =============================================================================
# SECTION 12: NON-BLOCKING DEPLOY-VERIFY FAILURE FLAGS (status.json)
# Non-blocking deploy-verify failures must record a DEGRADED_STAGES flag so
# the failure is written to status.json (.degraded_stages) and surfaces in the
# batch summary — issue comments alone are not read by the batch orchestrator.
# These are static-analysis tests (the failure paths live inline in main()),
# plus a functional test of the recording mechanism.
# =============================================================================

@test "deploy command failure appends a deploy_verify:deploy_failed flag" {
    local script_content
    script_content=$(< "$ORCHESTRATOR_SCRIPT")
    [[ "$script_content" == \
        *'DEGRADED_STAGES+=("deploy_verify:deploy_failed:exit=$deploy_exit")'* ]]
}

@test "health timeout appends a deploy_verify:health_timeout flag" {
    local script_content
    script_content=$(< "$ORCHESTRATOR_SCRIPT")
    [[ "$script_content" == \
        *'DEGRADED_STAGES+=("deploy_verify:health_timeout:attempts=$max_retries")'* ]]
}

@test "verify error/partial verdict appends a deploy_verify:verify_<status> flag" {
    local script_content
    script_content=$(< "$ORCHESTRATOR_SCRIPT")
    [[ "$script_content" == \
        *'DEGRADED_STAGES+=("deploy_verify:verify_$dv_status")'* ]]
}

@test "verify flag is gated on error or partial status only" {
    # The flag must not fire for success/unknown verdicts.
    local script_content
    script_content=$(< "$ORCHESTRATOR_SCRIPT")
    [[ "$script_content" == *'"$dv_status" == "error"'*'"$dv_status" == "partial"'* ]]
}

@test "deploy_verify flags are written to status.json .degraded_stages" {
    # Reproduce the recording block from main() (lines ~7957-7962) and assert
    # a deploy_verify flag lands in status.json.
    printf '{"state":"completed"}\n' > "$STATUS_FILE"
    local -a DEGRADED_STAGES=("deploy_verify:deploy_failed:exit=1")

    local degraded_json
    degraded_json=$(printf '%s\n' \
        "${DEGRADED_STAGES[@]+"${DEGRADED_STAGES[@]}"}" \
        | jq -R . | jq -s .)
    jq --argjson degraded "$degraded_json" \
        '.degraded_stages = $degraded' "$STATUS_FILE" \
        > "$STATUS_FILE.tmp" && mv "$STATUS_FILE.tmp" "$STATUS_FILE"

    run jq -r '.degraded_stages[0]' "$STATUS_FILE"
    [ "$status" -eq 0 ]
    [ "$output" = "deploy_verify:deploy_failed:exit=1" ]
}

@test "non-blocking deploy failure: stage completes AND flag is written to status.json" {
    # Functional test: exercises set_stage_completed() directly (not static string
    # matching) to assert the two invariants of a non-blocking deploy failure —
    # (a) the stage reaches "completed" so the pipeline is not halted, and
    # (b) the deploy_verify:deploy_failed flag lands in .degraded_stages so
    # the batch summary surfaces the failure without requiring a comment read.
    printf '{"state":"running","stages":{"deploy_verify":{"status":"started"}},"escalations":[]}\n' \
        > "$STATUS_FILE"

    # Simulate the orchestrator failure path from main():
    #   DEGRADED_STAGES+=("deploy_verify:deploy_failed:exit=$deploy_exit")
    #   set_stage_completed "deploy_verify"
    local -a DEGRADED_STAGES=("deploy_verify:deploy_failed:exit=127")
    set_stage_completed "deploy_verify"

    # Run the recording block that main() executes after all stages complete
    local degraded_json
    degraded_json=$(printf '%s\n' \
        "${DEGRADED_STAGES[@]+"${DEGRADED_STAGES[@]}"}" \
        | jq -R . | jq -s .)
    jq --argjson degraded "$degraded_json" \
        '.degraded_stages = $degraded' "$STATUS_FILE" \
        > "$STATUS_FILE.tmp" && mv "$STATUS_FILE.tmp" "$STATUS_FILE"

    # (a) Non-blocking: stage must be completed, not failed/errored
    run jq -r '.stages.deploy_verify.status' "$STATUS_FILE"
    [ "$status" -eq 0 ]
    [ "$output" = "completed" ]

    # (b) Visibility flag: failure must appear in .degraded_stages
    run jq -r '.degraded_stages[0]' "$STATUS_FILE"
    [ "$status" -eq 0 ]
    [[ "$output" == deploy_verify:deploy_failed:* ]]
}
