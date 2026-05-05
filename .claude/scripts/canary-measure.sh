#!/usr/bin/env bash
#
# canary-measure.sh
# Aggregate wall-clock and token usage per issue across a canary run.
#
# Used to gate AC5 of issue #179: tokens-per-issue regression ≤ 10%,
# wall-clock-per-issue regression ≤ 25%. The script reads metrics.json files
# emitted by implement-issue-orchestrator and matches them against transcript
# JSONL files in ~/.claude/projects/ to compute per-issue token totals.
#
# Usage (measurement mode):
#   canary-measure.sh --logs-dir <dir> [--transcripts-dir <dir>]
#                     [--label <name>] [--format json|markdown]
#                     [--limit N]
#
# Usage (delta mode):
#   canary-measure.sh --compute-deltas --before <json> --after <json>
#                     [--format json|markdown]
#
# Defaults:
#   --transcripts-dir  ~/.claude/projects
#   --format           json
#
# Issue→transcript matching:
#   A transcript JSONL record is attributed to issue N if its `cwd` field
#   equals the issue's log directory or any descendant path (e.g. worktrees/).
#
# Exit codes:
#   0 - success
#   1 - validation failure (missing args, bad inputs)
#

set -euo pipefail

# =============================================================================
# DEFAULTS / ARGUMENT PARSING
# =============================================================================

LOGS_DIR=""
TRANSCRIPTS_DIR="${HOME}/.claude/projects"
LABEL=""
FORMAT="json"
LIMIT=0
COMPUTE_DELTAS=0
BEFORE=""
AFTER=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --logs-dir)
            [[ $# -ge 2 ]] || { printf 'ERROR: %s requires a value\n' "$1" >&2; exit 1; }
            LOGS_DIR="$2"; shift 2;;
        --transcripts-dir)
            [[ $# -ge 2 ]] || { printf 'ERROR: %s requires a value\n' "$1" >&2; exit 1; }
            TRANSCRIPTS_DIR="$2"; shift 2;;
        --label)
            [[ $# -ge 2 ]] || { printf 'ERROR: %s requires a value\n' "$1" >&2; exit 1; }
            LABEL="$2"; shift 2;;
        --format)
            [[ $# -ge 2 ]] || { printf 'ERROR: %s requires a value\n' "$1" >&2; exit 1; }
            FORMAT="$2"; shift 2;;
        --limit)
            [[ $# -ge 2 ]] || { printf 'ERROR: %s requires a value\n' "$1" >&2; exit 1; }
            LIMIT="$2"; shift 2;;
        --compute-deltas)
            COMPUTE_DELTAS=1; shift;;
        --before)
            [[ $# -ge 2 ]] || { printf 'ERROR: %s requires a value\n' "$1" >&2; exit 1; }
            BEFORE="$2"; shift 2;;
        --after)
            [[ $# -ge 2 ]] || { printf 'ERROR: %s requires a value\n' "$1" >&2; exit 1; }
            AFTER="$2"; shift 2;;
        -h|--help)
            sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
        *)
            printf 'ERROR: unknown option: %s\n' "$1" >&2; exit 1;;
    esac
done

case "$FORMAT" in
    json|markdown) ;;
    *) printf 'ERROR: --format must be json or markdown\n' >&2; exit 1;;
esac

# =============================================================================
# DELTA MODE
# =============================================================================

if [[ "$COMPUTE_DELTAS" -eq 1 ]]; then
    [[ -f "$BEFORE" ]] || { printf 'ERROR: --before file not found: %s\n' "$BEFORE" >&2; exit 1; }
    [[ -f "$AFTER"  ]] || { printf 'ERROR: --after file not found: %s\n'  "$AFTER"  >&2; exit 1; }

    deltas=$(jq -n \
        --slurpfile b "$BEFORE" \
        --slurpfile a "$AFTER" \
        '
        def pct(before; after):
            if before == 0 or before == null then null
            else (((after - before) * 100) / before) | floor end;

        ($b[0].summary // {}) as $bs
        | ($a[0].summary // {}) as $as
        | {
            before_label: ($b[0].label // null),
            after_label:  ($a[0].label // null),
            before_summary: $bs,
            after_summary:  $as,
            deltas: {
                wall_clock_total_pct:  pct($bs.wall_clock_total;  $as.wall_clock_total),
                wall_clock_median_pct: pct($bs.wall_clock_median; $as.wall_clock_median),
                tokens_total_pct:      pct($bs.tokens_total;      $as.tokens_total),
                tokens_median_pct:     pct($bs.tokens_median;     $as.tokens_median)
            },
            gates: {
                tokens_pct_limit:     10,
                wall_clock_pct_limit: 25,
                tokens_within_limit:
                    ((pct($bs.tokens_median; $as.tokens_median) // 0) <= 10),
                wall_clock_within_limit:
                    ((pct($bs.wall_clock_median; $as.wall_clock_median) // 0) <= 25)
            }
        }
        ')

    if [[ "$FORMAT" = "json" ]]; then
        printf '%s\n' "$deltas"
    else
        printf '## Canary deltas: %s → %s\n\n' \
            "$(printf '%s' "$deltas" | jq -r '.before_label // "before"')" \
            "$(printf '%s' "$deltas" | jq -r '.after_label  // "after"')"
        printf '| Metric | Before | After | Δ%% | Gate |\n'
        printf '|---|---:|---:|---:|:---:|\n'
        printf '%s\n' "$deltas" | jq -r '
            "| Wall-clock total (s)  | \(.before_summary.wall_clock_total)  | \(.after_summary.wall_clock_total)  | \(.deltas.wall_clock_total_pct  // "n/a") | — |",
            "| Wall-clock median (s) | \(.before_summary.wall_clock_median) | \(.after_summary.wall_clock_median) | \(.deltas.wall_clock_median_pct // "n/a") | \(if .gates.wall_clock_within_limit then "PASS" else "FAIL" end) |",
            "| Tokens total          | \(.before_summary.tokens_total)      | \(.after_summary.tokens_total)      | \(.deltas.tokens_total_pct      // "n/a") | — |",
            "| Tokens median         | \(.before_summary.tokens_median)     | \(.after_summary.tokens_median)     | \(.deltas.tokens_median_pct     // "n/a") | \(if .gates.tokens_within_limit then "PASS" else "FAIL" end) |"
        '
    fi
    exit 0
fi

# =============================================================================
# MEASUREMENT MODE
# =============================================================================

[[ -n "$LOGS_DIR" ]] || { printf 'ERROR: --logs-dir is required\n' >&2; exit 1; }
[[ -d "$LOGS_DIR" ]] || { printf 'ERROR: --logs-dir not found: %s\n' "$LOGS_DIR" >&2; exit 1; }

# Discover metrics.json files (bash 3.2 compatible — no mapfile)
METRICS_FILES=()
while IFS= read -r _f; do
    [[ -n "$_f" ]] && METRICS_FILES+=("$_f")
done < <(find "$LOGS_DIR" -mindepth 2 -maxdepth 3 -name metrics.json -type f 2>/dev/null | sort)

if [[ "$LIMIT" -gt 0 && "${#METRICS_FILES[@]}" -gt "$LIMIT" ]]; then
    _start=$(( ${#METRICS_FILES[@]} - LIMIT ))
    METRICS_FILES=("${METRICS_FILES[@]:$_start}")
fi

if [[ "${#METRICS_FILES[@]}" -eq 0 ]]; then
    printf 'ERROR: no metrics.json files found under %s\n' "$LOGS_DIR" >&2
    exit 1
fi

# Sum tokens from transcripts whose cwd matches the issue's log directory
# (or any descendant path, e.g. worktrees/task-N).
#
# Transcripts in ~/.claude/projects/ are organized by directory whose name is
# the cwd with `/` replaced by `-` (e.g. /a/b/c → -a-b-c). To avoid loading all
# 10k+ transcript files, we pre-filter by parent-dir name; if that yields
# nothing (e.g. test fixtures with arbitrary names), we fall back to scanning
# all transcripts under TRANSCRIPTS_DIR. We always verify the cwd field inside
# each record matches log_dir (or a descendant).
sum_tokens_for_issue() {
    local log_dir="$1"
    local empty='{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"sessions":0}'

    if [[ ! -d "$TRANSCRIPTS_DIR" ]]; then
        printf '%s' "$empty"; return
    fi

    # Mangled directory prefix used by ~/.claude/projects/.
    local prefix="${log_dir//\//-}"

    local files=()
    while IFS= read -r _f; do
        [[ -n "$_f" ]] && files+=("$_f")
    done < <(find "$TRANSCRIPTS_DIR" -name '*.jsonl' -type f \
                  -path "*${prefix}*" 2>/dev/null)

    # Fallback: small test fixtures often don't follow the mangled-name scheme.
    # If the prefix filter found nothing, scan all and rely on cwd verification.
    if [[ "${#files[@]}" -eq 0 ]]; then
        while IFS= read -r _f; do
            [[ -n "$_f" ]] && files+=("$_f")
        done < <(find "$TRANSCRIPTS_DIR" -name '*.jsonl' -type f 2>/dev/null)
    fi

    if [[ "${#files[@]}" -eq 0 ]]; then
        printf '%s' "$empty"; return
    fi

    # Stream-process per file, verifying cwd in each record. Avoids loading
    # everything into a single jq slurp.
    local sessions=0
    local seen_session
    local stream_output
    stream_output=$(for f in "${files[@]}"; do
        jq -c --arg root "$log_dir" '
            select(.cwd != null and .message.usage != null
                   and (.cwd == $root or (.cwd | startswith($root + "/"))))
            | .message.usage
            | {input_tokens: (.input_tokens // 0),
               output_tokens: (.output_tokens // 0),
               cache_creation_input_tokens: (.cache_creation_input_tokens // 0),
               cache_read_input_tokens: (.cache_read_input_tokens // 0)}' \
            "$f" 2>/dev/null \
        && { seen_session=1; printf '%s\n' "__SESSION__"; }
    done)

    sessions=$(printf '%s\n' "$stream_output" | grep -c '^__SESSION__$' || true)
    local records
    records=$(printf '%s\n' "$stream_output" | grep -v '^__SESSION__$')

    if [[ -z "$records" ]]; then
        printf '{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"sessions":%d}' "$sessions"
        return
    fi

    local agg
    agg=$(printf '%s\n' "$records" | jq -s --argjson n "$sessions" '
        {
            input_tokens:               (map(.input_tokens               // 0) | add // 0),
            output_tokens:              (map(.output_tokens              // 0) | add // 0),
            cache_creation_input_tokens:(map(.cache_creation_input_tokens // 0) | add // 0),
            cache_read_input_tokens:    (map(.cache_read_input_tokens     // 0) | add // 0),
            sessions: $n
        }')
    if [[ -n "$agg" ]]; then
        printf '%s' "$agg"
    else
        printf '%s' "$empty"
    fi
}

# Build per-issue rows
ISSUE_ROWS=()
for mf in "${METRICS_FILES[@]}"; do
    log_dir="$(dirname "$mf")"
    issue=$(jq -r '.issue // empty' "$mf")
    duration=$(jq -r '.total_duration_seconds // 0' "$mf")
    started=$(jq -r '.started_at // empty' "$mf")
    completed=$(jq -r '.completed_at // empty' "$mf")
    state=$(jq -r '.state // empty' "$mf")

    [[ -n "$issue" ]] || continue

    tokens_json=$(sum_tokens_for_issue "$log_dir")

    row=$(jq -n \
        --arg issue "$issue" \
        --arg log_dir "$log_dir" \
        --arg started "$started" \
        --arg completed "$completed" \
        --arg state "$state" \
        --argjson duration "$duration" \
        --argjson tok "$tokens_json" \
        '{
            issue: $issue,
            log_dir: $log_dir,
            state: $state,
            started_at: $started,
            completed_at: $completed,
            wall_clock_seconds: $duration,
            input_tokens:                $tok.input_tokens,
            output_tokens:               $tok.output_tokens,
            cache_creation_input_tokens: $tok.cache_creation_input_tokens,
            cache_read_input_tokens:     $tok.cache_read_input_tokens,
            transcript_sessions:         $tok.sessions,
            total_tokens: ($tok.input_tokens + $tok.output_tokens
                          + $tok.cache_creation_input_tokens
                          + $tok.cache_read_input_tokens)
         }')
    ISSUE_ROWS+=("$row")
done

# Aggregate summary
ALL_ROWS_JSON=$(printf '%s\n' "${ISSUE_ROWS[@]}" | jq -s '.')

SUMMARY=$(printf '%s' "$ALL_ROWS_JSON" | jq '
    def median: sort | if length == 0 then 0
        elif length % 2 == 1 then .[length/2|floor]
        else ((.[length/2 - 1] + .[length/2]) / 2 | floor) end;

    {
        count: length,
        wall_clock_total:  ([.[].wall_clock_seconds] | add // 0),
        wall_clock_median: ([.[].wall_clock_seconds] | median),
        tokens_total:      ([.[].total_tokens]       | add // 0),
        tokens_median:     ([.[].total_tokens]       | median),
        input_tokens_total:  ([.[].input_tokens]                | add // 0),
        output_tokens_total: ([.[].output_tokens]               | add // 0),
        cache_creation_total:([.[].cache_creation_input_tokens] | add // 0),
        cache_read_total:    ([.[].cache_read_input_tokens]     | add // 0)
    }
')

REPORT=$(jq -n \
    --arg label "$LABEL" \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg logs_dir "$LOGS_DIR" \
    --arg transcripts_dir "$TRANSCRIPTS_DIR" \
    --argjson issues "$ALL_ROWS_JSON" \
    --argjson summary "$SUMMARY" \
    '{
        label: (if $label == "" then null else $label end),
        generated_at: $generated_at,
        logs_dir: $logs_dir,
        transcripts_dir: $transcripts_dir,
        summary: $summary,
        issues: $issues
     }')

if [[ "$FORMAT" = "json" ]]; then
    printf '%s\n' "$REPORT"
    exit 0
fi

# Markdown output
{
    label_disp=$(printf '%s' "$REPORT" | jq -r '.label // "unlabeled"')
    printf '## Canary measurement: %s\n\n' "$label_disp"
    printf 'Generated: %s\n' "$(printf '%s' "$REPORT" | jq -r '.generated_at')"
    printf 'Logs dir: `%s`\n' "$(printf '%s' "$REPORT" | jq -r '.logs_dir')"
    printf 'Issues: %s\n\n' "$(printf '%s' "$REPORT" | jq -r '.summary.count')"

    printf '### Per-issue\n\n'
    printf '| Issue | State | Wall-clock (s) | Total tokens | Input | Output | Cache create | Cache read | Sessions |\n'
    printf '|---|---|---:|---:|---:|---:|---:|---:|---:|\n'
    printf '%s' "$REPORT" | jq -r '.issues[] |
        "| \(.issue) | \(.state // "?") | \(.wall_clock_seconds) | \(.total_tokens) | \(.input_tokens) | \(.output_tokens) | \(.cache_creation_input_tokens) | \(.cache_read_input_tokens) | \(.transcript_sessions) |"'

    printf '\n### Summary\n\n'
    printf '| Metric | Value |\n|---|---:|\n'
    printf '%s' "$REPORT" | jq -r '.summary |
        "| Issues counted | \(.count) |",
        "| Wall-clock total (s) | \(.wall_clock_total) |",
        "| Median wall-clock (s) | \(.wall_clock_median) |",
        "| Tokens total | \(.tokens_total) |",
        "| Median tokens | \(.tokens_median) |",
        "| Input tokens total | \(.input_tokens_total) |",
        "| Output tokens total | \(.output_tokens_total) |",
        "| Cache-creation tokens | \(.cache_creation_total) |",
        "| Cache-read tokens | \(.cache_read_total) |"'
}
