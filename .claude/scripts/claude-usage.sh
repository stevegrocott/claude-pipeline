#!/usr/bin/env bash
#
# claude-usage.sh — Proactive usage polling for the Claude.ai usage API
#
# Queries the (private) endpoint that Sneaky Penguin and similar menu-bar apps
# poll. Lets the orchestrator skip a model whose per-model bucket is exhausted
# by escalating via _next_model_up — without sleeping for the rate-limit reset.
#
# This module is sourced by orchestrator scripts. It exposes:
#   fetch_usage              — populate / refresh the cache (30s TTL)
#   usage_for_model MODEL    — utilization 0..100 with bucket fallback
#   model_reset_at MODEL     — ISO8601 timestamp or "unknown"
#   is_model_exhausted MODEL — 0/1, applies all guards in order
#
# Hybrid fallback: if CLAUDE_USAGE_SESSION_KEY is unset OR any fetch fails,
# is_model_exhausted returns false for everything. Caller behaves as today.
#
# Security: sessionKey is treated as a bearer-equivalent secret. Read once
# into a local variable, passed to curl via -H Cookie:, never echoed, never
# logged, never written to status.json or any artifact.
#

# Guard against double-sourcing — orchestrator and batch-orchestrator may
# both source this. Function definitions are idempotent but the cache-path
# computation is wasteful to repeat.
if [[ -n "${_CLAUDE_USAGE_SOURCED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_CLAUDE_USAGE_SOURCED=1

# Cache file under XDG_CACHE_HOME so it's user-scoped (one source of truth
# across all worktrees / projects) and never accidentally committed.
_CLAUDE_USAGE_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-pipeline"
_CLAUDE_USAGE_CACHE_FILE="$_CLAUDE_USAGE_CACHE_DIR/usage.json"

# Defaults (overridable via env). See SKILL.md for semantics.
: "${CLAUDE_USAGE_CACHE_TTL:=30}"
: "${CLAUDE_USAGE_SESSION_THRESHOLD:=95}"
: "${CLAUDE_USAGE_MODEL_THRESHOLD:=95}"
: "${CLAUDE_USAGE_WEEKLY_THRESHOLD:=98}"
: "${CLAUDE_USAGE_EXTRA_THRESHOLD:=90}"

# --- internal helpers ------------------------------------------------------

_usage_log() {
    # Stage-runner ships a `log` function; if not present, fall back to stderr.
    # All claude-usage messages go to stderr — never stdout (we return values
    # there).
    if declare -F log >/dev/null 2>&1; then
        log "$@"
    else
        printf '[%s] %s\n' "$(date -Iseconds 2>/dev/null || date)" "$*" >&2
    fi
}

_usage_warn() { _usage_log "WARN claude-usage: $*"; }
_usage_error() { _usage_log "ERROR claude-usage: $*"; }

_cache_age_seconds() {
    [[ -f "$_CLAUDE_USAGE_CACHE_FILE" ]] || { printf '999999\n'; return; }
    local mtime now
    mtime=$(stat -f %m "$_CLAUDE_USAGE_CACHE_FILE" 2>/dev/null \
         || stat -c %Y "$_CLAUDE_USAGE_CACHE_FILE" 2>/dev/null \
         || echo 0)
    now=$(date +%s)
    printf '%s\n' $((now - mtime))
}

_session_key_value() {
    # Resolution order: env var > file (with newline strip).
    if [[ -n "${CLAUDE_USAGE_SESSION_KEY:-}" ]]; then
        printf '%s' "$CLAUDE_USAGE_SESSION_KEY"
        return 0
    fi
    if [[ -n "${CLAUDE_USAGE_SESSION_KEY_FILE:-}" && -r "${CLAUDE_USAGE_SESSION_KEY_FILE}" ]]; then
        tr -d '[:space:]' < "$CLAUDE_USAGE_SESSION_KEY_FILE"
        return 0
    fi
    return 1
}

# --- fetch_usage -----------------------------------------------------------
# Returns 0 on success (cache populated and valid), non-zero on any failure.
# Side effect: writes cache file. Failures are logged but never raise.

fetch_usage() {
    if [[ "${CLAUDE_USAGE_DISABLE:-0}" == "1" ]]; then
        return 1
    fi

    # Cache hit?
    local age
    age=$(_cache_age_seconds)
    if (( age <= CLAUDE_USAGE_CACHE_TTL )) && [[ -f "$_CLAUDE_USAGE_CACHE_FILE" ]]; then
        return 0
    fi

    local session_key
    if ! session_key=$(_session_key_value); then
        # Unconfigured — silent no-op so non-users see no churn.
        return 1
    fi

    if [[ -z "${CLAUDE_USAGE_ORG_ID:-}" ]]; then
        _usage_warn "CLAUDE_USAGE_SESSION_KEY set but CLAUDE_USAGE_ORG_ID is not — skipping fetch"
        return 1
    fi

    mkdir -p "$_CLAUDE_USAGE_CACHE_DIR"

    # Track whether the cache was previously valid — drives WARN vs ERROR
    # severity on failure (regression-after-success is louder than first-fail).
    local had_valid_cache=0
    if [[ -f "$_CLAUDE_USAGE_CACHE_FILE" ]] && jq empty "$_CLAUDE_USAGE_CACHE_FILE" 2>/dev/null; then
        had_valid_cache=1
    fi

    local body_file http_status
    body_file=$(mktemp)
    # Trap-free cleanup: the function caller may also have traps; we just
    # rm at end of function.

    # NOTE: the sessionKey is interpolated into a HEADER VALUE (-H), not into
    # a positional arg. /proc/PID/cmdline shows positional args; headers are
    # not visible to ps. Read-once into local variable; never logged.
    http_status=$(curl -sS \
        --connect-timeout 3 \
        --max-time 5 \
        -o "$body_file" \
        -w '%{http_code}' \
        -H "Cookie: sessionKey=${session_key}" \
        -H "Accept: application/json" \
        "https://claude.ai/api/organizations/${CLAUDE_USAGE_ORG_ID}/usage" 2>/dev/null) \
        || http_status="000"

    # Clear local references to the secret immediately after the curl call.
    session_key=""

    if [[ "$http_status" != "200" ]]; then
        _log_fetch_failure "$had_valid_cache" "fetch failed (HTTP $http_status)" "endpoint regression?"
        rm -f "$body_file"
        return 1
    fi

    if ! jq empty "$body_file" 2>/dev/null; then
        _log_fetch_failure "$had_valid_cache" "response is not valid JSON" "endpoint shape changed?"
        rm -f "$body_file"
        return 1
    fi

    # Atomic install (tmp + mv). Pretty-printed for ad-hoc inspection.
    jq . "$body_file" > "${_CLAUDE_USAGE_CACHE_FILE}.tmp" && \
        mv "${_CLAUDE_USAGE_CACHE_FILE}.tmp" "$_CLAUDE_USAGE_CACHE_FILE"

    rm -f "$body_file"
    return 0
}

# Cache-was-valid escalates WARN to ERROR — a regression-after-success is
# louder than first-time failure (which usually means unconfigured / new user).
_log_fetch_failure() {
    local had_valid="$1" msg="$2" regression_suffix="$3"
    if (( had_valid )); then
        _usage_error "$msg after prior success — $regression_suffix"
    else
        _usage_warn "$msg"
    fi
}

# --- bucket-mapped accessors ----------------------------------------------

_per_model_field() {
    case "$1" in
        sonnet) printf 'seven_day_sonnet' ;;
        opus)   printf 'seven_day_opus' ;;
        *)      printf '' ;;
    esac
}

# Models known to share the seven_day all-models bucket when no per-model
# field exists. Haiku is here; truly unknown models are NOT — for those we
# return 0 so the gating logic can't accidentally throttle a model the
# script doesn't recognize.
_is_known_model() {
    case "$1" in
        sonnet|opus|haiku) return 0 ;;
        *) return 1 ;;
    esac
}

# Pick PER_MODEL_FIELD.PROP if non-null, else seven_day.PROP, else DEFAULT.
# One jq invocation, returns the resolved value via stdout.
_bucket_pick() {
    local field="$1" prop="$2" default="$3"
    jq -r --arg f "$field" --arg p "$prop" --arg d "$default" '
        def pick(p): . as $o | if $o[p] == null or $o[p] == "" then null else $o[p] end;
        (if $f != "" then (.[$f] // {}) | pick($p) else null end) //
        ((.seven_day // {}) | pick($p)) //
        $d
    ' "$_CLAUDE_USAGE_CACHE_FILE" 2>/dev/null
}

# usage_for_model MODEL → integer 0..100 (or 0 on unknown / no data)
usage_for_model() {
    local model="$1"
    _is_known_model "$model" || { printf '0\n'; return 0; }

    fetch_usage || { printf '0\n'; return 0; }
    [[ -f "$_CLAUDE_USAGE_CACHE_FILE" ]] || { printf '0\n'; return 0; }

    local val
    val=$(_bucket_pick "$(_per_model_field "$model")" utilization 0)
    printf '%.0f\n' "${val:-0}"
}

# model_reset_at MODEL → ISO8601 string or "unknown"
model_reset_at() {
    local model="$1"
    fetch_usage || { printf 'unknown\n'; return 0; }
    [[ -f "$_CLAUDE_USAGE_CACHE_FILE" ]] || { printf 'unknown\n'; return 0; }

    local val
    val=$(_bucket_pick "$(_per_model_field "$model")" resets_at unknown)
    printf '%s\n' "${val:-unknown}"
}

# --- is_model_exhausted ----------------------------------------------------
# Three-gate check, in order of recovery cost:
#   1. five_hour (shared session) — hard cap, overage cannot absorb a rate
#      window. Crossing it kills every model.
#   2. per-model weekly — soft cap; if extra_usage is_enabled and below its
#      own threshold, calls drain against overage and we should NOT escalate.
#   3. seven_day (all-models weekly) — treated as hard cap (conservative).
#      Empirical verification of overage absorption deferred to a follow-up.

is_model_exhausted() {
    local model="$1"

    if [[ "${CLAUDE_USAGE_DISABLE:-0}" == "1" ]]; then
        return 1
    fi

    fetch_usage || return 1   # graceful: no data, treat as not exhausted
    [[ -f "$_CLAUDE_USAGE_CACHE_FILE" ]] || return 1

    # One jq, five fields, TSV. Empty string for missing per-model bucket
    # (haiku, unknowns) — bash arithmetic later treats it as 0 / not-exhausted.
    local field five_hour_pct seven_day_pct extra_enabled extra_pct per_model_pct
    field=$(_per_model_field "$model")
    IFS=$'\t' read -r five_hour_pct seven_day_pct extra_enabled extra_pct per_model_pct < <(
        jq -r --arg f "$field" '
            [
                (.five_hour.utilization // 0),
                (.seven_day.utilization // 0),
                (.extra_usage.is_enabled // false),
                (.extra_usage.utilization // 0),
                (if $f != "" then (.[$f] // {}) | (.utilization // "") else "" end)
            ] | @tsv
        ' "$_CLAUDE_USAGE_CACHE_FILE" 2>/dev/null
    )

    five_hour_pct=$(printf '%.0f' "${five_hour_pct:-0}")
    seven_day_pct=$(printf '%.0f' "${seven_day_pct:-0}")
    extra_pct=$(printf '%.0f' "${extra_pct:-0}")

    # 1. Session gate — overage cannot absorb a rate window.
    if (( five_hour_pct >= CLAUDE_USAGE_SESSION_THRESHOLD )); then
        return 0
    fi

    # 2. Per-model weekly with overage absorption guard.
    if [[ -n "$per_model_pct" ]]; then
        per_model_pct=$(printf '%.0f' "$per_model_pct")
        if (( per_model_pct >= CLAUDE_USAGE_MODEL_THRESHOLD )); then
            if [[ "$extra_enabled" == "true" ]] && (( extra_pct < CLAUDE_USAGE_EXTRA_THRESHOLD )); then
                : # overage absorbing — fall through to weekly check
            else
                return 0
            fi
        fi
    fi

    # 3. All-models weekly — treated as hard cap (conservative; see SKILL).
    if (( seven_day_pct >= CLAUDE_USAGE_WEEKLY_THRESHOLD )); then
        return 0
    fi

    return 1
}
