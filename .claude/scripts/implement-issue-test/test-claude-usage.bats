#!/usr/bin/env bats
#
# test-claude-usage.bats
#
# Tests for the proactive usage-polling module (claude-usage.sh).
#
# Module under test exposes:
#   fetch_usage()              - reads cache (30s TTL) or curls the API
#   usage_for_model(model)     - 0..100 with bucket fallback (per-model -> seven_day)
#   model_reset_at(model)      - ISO8601 string or "unknown" if null
#   is_model_exhausted(model)  - applies session/per-model/weekly thresholds + overage guard
#
# Mocking strategy: install a mock `curl` in PATH that reads its response body
# from $MOCK_CURL_BODY_FILE and exit code from $MOCK_CURL_EXIT_CODE. Tests
# control the cache file directly to test TTL boundaries without wall-clock.
#

load 'helpers/test-helper.bash'

setup() {
    setup_test_env

    REAL_SCRIPT_DIR="$SCRIPT_DIR"
    FIXTURE="$REAL_SCRIPT_DIR/implement-issue-test/fixtures/usage-response.json"

    # Install mock curl into the test PATH.
    local mock_bin="$TEST_TMP/bin"
    mkdir -p "$mock_bin"
    cat > "$mock_bin/curl" <<'CURL_MOCK'
#!/usr/bin/env bash
# Mock curl: writes body from $MOCK_CURL_BODY_FILE to -o output, prints
# $MOCK_CURL_HTTP_STATUS for -w '%{http_code}', exits with $MOCK_CURL_EXIT_CODE.
out_file=""
write_format=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) out_file="$2"; shift 2 ;;
        -w) write_format="$2"; shift 2 ;;
        *)  shift ;;
    esac
done
if [[ -n "${MOCK_CURL_BODY_FILE:-}" && -r "$MOCK_CURL_BODY_FILE" ]]; then
    if [[ -n "$out_file" ]]; then
        cat "$MOCK_CURL_BODY_FILE" > "$out_file"
    else
        cat "$MOCK_CURL_BODY_FILE"
    fi
fi
if [[ "$write_format" == *"%{http_code}"* ]]; then
    printf '%s' "${MOCK_CURL_HTTP_STATUS:-200}"
fi
# Track invocation count so tests can assert TTL behavior.
ctr_file="${MOCK_CURL_COUNTER_FILE:-/tmp/mock_curl_ctr.$$}"
n=0
[[ -f "$ctr_file" ]] && n=$(cat "$ctr_file")
echo $((n + 1)) > "$ctr_file"
exit "${MOCK_CURL_EXIT_CODE:-0}"
CURL_MOCK
    chmod +x "$mock_bin/curl"

    # Per-test cache directory (override XDG_CACHE_HOME).
    export XDG_CACHE_HOME="$TEST_TMP/cache"
    mkdir -p "$XDG_CACHE_HOME"

    # Per-test mock state.
    export MOCK_CURL_BODY_FILE="$FIXTURE"
    export MOCK_CURL_HTTP_STATUS=200
    export MOCK_CURL_EXIT_CODE=0
    export MOCK_CURL_COUNTER_FILE="$TEST_TMP/curl-ctr"
    rm -f "$MOCK_CURL_COUNTER_FILE"

    # Default config — set after helper sources to avoid leaking to other tests.
    export CLAUDE_USAGE_SESSION_KEY="sk-ant-sid01-test-fake-key-do-not-leak"
    export CLAUDE_USAGE_ORG_ID="00000000-0000-0000-0000-000000000000"
    export CLAUDE_USAGE_CACHE_TTL=30
    export CLAUDE_USAGE_SESSION_THRESHOLD=95
    export CLAUDE_USAGE_MODEL_THRESHOLD=95
    export CLAUDE_USAGE_WEEKLY_THRESHOLD=98
    export CLAUDE_USAGE_EXTRA_THRESHOLD=90
    unset CLAUDE_USAGE_DISABLE CLAUDE_USAGE_SESSION_KEY_FILE || true

    # Mock binary path takes precedence.
    export PATH="$mock_bin:$PATH"

    # Source the module under test.
    # shellcheck disable=SC1091
    source "$REAL_SCRIPT_DIR/claude-usage.sh"
}

teardown() {
    teardown_test_env
}

# Helper: write a usage JSON to a temp file and point the mock at it.
make_usage_response() {
    local file="$TEST_TMP/usage-resp.json"
    cat > "$file"
    export MOCK_CURL_BODY_FILE="$file"
}

# ============================================================================
# fetch_usage / cache TTL
# ============================================================================

@test "01 fetch_usage returns 0 and writes cache file on first call" {
    run fetch_usage
    [ "$status" -eq 0 ]
    [ -f "$XDG_CACHE_HOME/claude-pipeline/usage.json" ]
    # Cache must contain the FULL response (not just computed pcts).
    cached_pct=$(jq -r '.seven_day_sonnet.utilization' "$XDG_CACHE_HOME/claude-pipeline/usage.json")
    [ "$cached_pct" = "100" ]
}

@test "02 fetch_usage uses cache within TTL — second call doesn't curl again" {
    fetch_usage  # first call populates cache
    fetch_usage  # second call within TTL
    n=$(cat "$MOCK_CURL_COUNTER_FILE")
    [ "$n" -eq 1 ]
}

@test "03 fetch_usage re-curls when cache is older than TTL" {
    fetch_usage
    # Backdate the cache file to 1h ago (well past 30s TTL).
    touch -t "$(date -v-1H +%Y%m%d%H%M.%S 2>/dev/null || date -d '1 hour ago' +%Y%m%d%H%M.%S)" \
        "$XDG_CACHE_HOME/claude-pipeline/usage.json"
    fetch_usage
    n=$(cat "$MOCK_CURL_COUNTER_FILE")
    [ "$n" -eq 2 ]
}

# ============================================================================
# usage_for_model — bucket mapping (per real fixture)
# ============================================================================

@test "10 usage_for_model sonnet → seven_day_sonnet utilization (100)" {
    run usage_for_model sonnet
    [ "$status" -eq 0 ]
    [ "$output" = "100" ]
}

@test "11 usage_for_model opus → seven_day_opus is null in fixture → falls back to seven_day (88)" {
    run usage_for_model opus
    [ "$status" -eq 0 ]
    [ "$output" = "88" ]
}

@test "12 usage_for_model haiku → no per-model bucket → uses seven_day (88)" {
    run usage_for_model haiku
    [ "$status" -eq 0 ]
    [ "$output" = "88" ]
}

@test "13 usage_for_model unknown model → returns 0 (don't gate the unknown)" {
    run usage_for_model nonsense
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

# ============================================================================
# model_reset_at — null guard
# ============================================================================

@test "20 model_reset_at sonnet returns the seven_day_sonnet timestamp" {
    run model_reset_at sonnet
    [ "$status" -eq 0 ]
    [[ "$output" == "2026-05-02T05:59:59"* ]]
}

@test "21 model_reset_at gracefully handles null resets_at" {
    make_usage_response <<'JSON'
{
  "five_hour": {"utilization": 0, "resets_at": null},
  "seven_day": {"utilization": 0, "resets_at": null},
  "seven_day_sonnet": {"utilization": 0, "resets_at": null},
  "seven_day_opus": null,
  "extra_usage": {"is_enabled": false, "utilization": 0}
}
JSON
    run model_reset_at sonnet
    [ "$status" -eq 0 ]
    [ "$output" = "unknown" ]
}

# ============================================================================
# is_model_exhausted — threshold ordering and overage guard
# ============================================================================

@test "30 sonnet at 100% (per fixture) AND extra_usage NOT enabled → exhausted" {
    make_usage_response <<'JSON'
{
  "five_hour": {"utilization": 2, "resets_at": "2026-05-02T07:09:59+00:00"},
  "seven_day": {"utilization": 88, "resets_at": "2026-05-02T05:59:59+00:00"},
  "seven_day_sonnet": {"utilization": 100, "resets_at": "2026-05-02T05:59:59+00:00"},
  "seven_day_opus": null,
  "extra_usage": {"is_enabled": false, "utilization": 0}
}
JSON
    run is_model_exhausted sonnet
    [ "$status" -eq 0 ]
}

@test "31 sonnet at 100% AND extra_usage enabled at 1% → NOT exhausted (overage absorbs)" {
    # This is the fixture's actual state — 100% sonnet, extra_usage enabled,
    # 1.18% used. Overage absorbs the per-model overflow; no escalation.
    run is_model_exhausted sonnet
    [ "$status" -ne 0 ]
}

@test "32 sonnet at 100% AND extra_usage enabled but at 95% → exhausted (overage near cap)" {
    make_usage_response <<'JSON'
{
  "five_hour": {"utilization": 2, "resets_at": "2026-05-02T07:09:59+00:00"},
  "seven_day": {"utilization": 88, "resets_at": "2026-05-02T05:59:59+00:00"},
  "seven_day_sonnet": {"utilization": 100, "resets_at": "2026-05-02T05:59:59+00:00"},
  "seven_day_opus": null,
  "extra_usage": {"is_enabled": true, "utilization": 95, "monthly_limit": 31000, "used_credits": 29450, "currency": "AUD"}
}
JSON
    run is_model_exhausted sonnet
    [ "$status" -eq 0 ]
}

@test "33 five_hour at 99% → ALL models exhausted regardless of weekly state" {
    make_usage_response <<'JSON'
{
  "five_hour": {"utilization": 99, "resets_at": "2026-05-02T07:09:59+00:00"},
  "seven_day": {"utilization": 5, "resets_at": "2026-05-02T05:59:59+00:00"},
  "seven_day_sonnet": {"utilization": 5, "resets_at": "2026-05-02T05:59:59+00:00"},
  "seven_day_opus": null,
  "extra_usage": {"is_enabled": true, "utilization": 0}
}
JSON
    run is_model_exhausted sonnet; [ "$status" -eq 0 ]
    run is_model_exhausted opus;   [ "$status" -eq 0 ]
    run is_model_exhausted haiku;  [ "$status" -eq 0 ]
}

@test "34 five_hour rate cap is NOT absorbed by extra_usage (rate window != token budget)" {
    make_usage_response <<'JSON'
{
  "five_hour": {"utilization": 99, "resets_at": "2026-05-02T07:09:59+00:00"},
  "seven_day": {"utilization": 5, "resets_at": "2026-05-02T05:59:59+00:00"},
  "seven_day_sonnet": {"utilization": 5, "resets_at": "2026-05-02T05:59:59+00:00"},
  "seven_day_opus": null,
  "extra_usage": {"is_enabled": true, "utilization": 1}
}
JSON
    run is_model_exhausted sonnet
    [ "$status" -eq 0 ]
}

@test "35 seven_day at 99% → exhausted (above weekly threshold 98)" {
    make_usage_response <<'JSON'
{
  "five_hour": {"utilization": 5, "resets_at": "2026-05-02T07:09:59+00:00"},
  "seven_day": {"utilization": 99, "resets_at": "2026-05-02T05:59:59+00:00"},
  "seven_day_sonnet": {"utilization": 5, "resets_at": "2026-05-02T05:59:59+00:00"},
  "seven_day_opus": null,
  "extra_usage": {"is_enabled": false, "utilization": 0}
}
JSON
    run is_model_exhausted opus
    [ "$status" -eq 0 ]
}

@test "36 all-clear state (per fixture five_hour=2, seven_day=88) → opus NOT exhausted" {
    run is_model_exhausted opus
    [ "$status" -ne 0 ]
}

# ============================================================================
# Configuration / hybrid fallback
# ============================================================================

@test "40 CLAUDE_USAGE_DISABLE=1 → is_model_exhausted always returns false" {
    export CLAUDE_USAGE_DISABLE=1
    # Even with the exhausted fixture, opt-out makes us return false.
    run is_model_exhausted sonnet
    [ "$status" -ne 0 ]
}

@test "41 missing CLAUDE_USAGE_SESSION_KEY → graceful: returns false, never curls" {
    unset CLAUDE_USAGE_SESSION_KEY
    run is_model_exhausted sonnet
    [ "$status" -ne 0 ]
    # Mock curl counter must be zero — we should never have invoked curl.
    n=$(cat "$MOCK_CURL_COUNTER_FILE" 2>/dev/null || echo 0)
    [ "$n" -eq 0 ]
}

@test "42 sessionKey can come from CLAUDE_USAGE_SESSION_KEY_FILE (0600)" {
    unset CLAUDE_USAGE_SESSION_KEY
    local key_file="$TEST_TMP/.session-key"
    printf 'sk-ant-sid01-from-file\n' > "$key_file"
    chmod 600 "$key_file"
    export CLAUDE_USAGE_SESSION_KEY_FILE="$key_file"

    run fetch_usage
    [ "$status" -eq 0 ]
    [ -f "$XDG_CACHE_HOME/claude-pipeline/usage.json" ]
}

# ============================================================================
# Failure modes
# ============================================================================

@test "50 HTTP non-200 → returns false, logs WARN" {
    export MOCK_CURL_HTTP_STATUS=401
    run fetch_usage 2>&1
    [ "$status" -ne 0 ]
    [[ "$output" == *"WARN"* || "$output" == *"warn"* ]]
}

@test "51 invalid JSON body → returns false, logs WARN" {
    local bad="$TEST_TMP/bad-body.txt"
    printf 'not json at all\n' > "$bad"
    export MOCK_CURL_BODY_FILE="$bad"
    run fetch_usage 2>&1
    [ "$status" -ne 0 ]
    [[ "$output" == *"WARN"* || "$output" == *"warn"* ]]
}

@test "52 cache-was-valid then fetch fails → ERROR log (regression detected)" {
    # First call succeeds → cache valid.
    fetch_usage
    [ -f "$XDG_CACHE_HOME/claude-pipeline/usage.json" ]
    # Backdate cache so it expires; next fetch returns 500.
    touch -t "$(date -v-1H +%Y%m%d%H%M.%S 2>/dev/null || date -d '1 hour ago' +%Y%m%d%H%M.%S)" \
        "$XDG_CACHE_HOME/claude-pipeline/usage.json"
    export MOCK_CURL_HTTP_STATUS=500
    run fetch_usage 2>&1
    [ "$status" -ne 0 ]
    [[ "$output" == *"ERROR"* || "$output" == *"error"* ]]
}

@test "53 graceful: failure path → is_model_exhausted returns false" {
    export MOCK_CURL_HTTP_STATUS=503
    run is_model_exhausted sonnet
    [ "$status" -ne 0 ]   # not exhausted (graceful fallback to today's behavior)
}

# ============================================================================
# Security: sessionKey must NEVER appear in any log output
# ============================================================================

@test "60 sessionKey value never appears in stdout, stderr, or any log line" {
    # Trigger every code path that touches the key.
    fetch_usage 2>&1 > "$TEST_TMP/stdout.txt"
    is_model_exhausted sonnet 2>&1 > "$TEST_TMP/stdout2.txt" || true
    model_reset_at sonnet 2>&1 > "$TEST_TMP/stdout3.txt" || true

    # Trigger failure path too.
    export MOCK_CURL_HTTP_STATUS=401
    fetch_usage 2>&1 >> "$TEST_TMP/stdout.txt" || true

    # The sessionKey must not appear in ANY captured output.
    if grep -q "$CLAUDE_USAGE_SESSION_KEY" "$TEST_TMP/stdout.txt" \
                                             "$TEST_TMP/stdout2.txt" \
                                             "$TEST_TMP/stdout3.txt"; then
        echo "LEAK: sessionKey appeared in script output" >&2
        return 1
    fi
}
