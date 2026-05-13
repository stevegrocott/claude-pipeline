#!/usr/bin/env bash
#
# analyze-wall-time.sh — Report wall-time distribution per pipeline phase
#
# Reads metrics.json + events.jsonl + orchestrator.log from each completed
# implement-issue run and prints p50/p75/p90/max for:
#   - Implement stage duration
#   - Wall time before test loop starts (= implement + quality + overhead)
#   - Wall time before PR-review loop starts (includes test loop)
#   - Test loop total duration (when test iterations > 0)
#   - PR-review loop total duration
#   - First PR-review iteration (review agent + fix agent) from events.jsonl
#   - PR-review iter-1 broken out by diff-size bucket (<50 / <200 / 200+ lines)
#   - Overall run duration
#
# Usage: analyze-wall-time.sh [options] [logs-dir]
#
# Arguments:
#   logs-dir    Root of the implement-issue log tree
#               (default: logs/implement-issue relative to repo root)
#
# Options:
#   -h, --help       Show this help message
#   -j, --json       Emit results as JSON instead of a human-readable table
#   -n, --count N    Analyze only the N most recent runs (default: all)
#   -v, --verbose    Show per-run detail table on stderr

set -o pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

die() { echo "$SCRIPT_NAME: $*" >&2; exit 1; }

JSON_OUTPUT=false
VERBOSE=false
COUNT=0
LOGS_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,2\}//' | sed '/^!/d'; exit 0 ;;
    -j|--json) JSON_OUTPUT=true; shift ;;
    -v|--verbose) VERBOSE=true; shift ;;
    -n|--count) COUNT="$2"; shift 2 ;;
    -*) die "Unknown option: $1" ;;
    *) LOGS_DIR="$1"; shift ;;
  esac
done

[[ -z "$LOGS_DIR" ]] && LOGS_DIR="$REPO_ROOT/logs/implement-issue"
[[ -d "$LOGS_DIR" ]] || die "Logs directory not found: $LOGS_DIR"

command -v python3 >/dev/null 2>&1 || die "python3 is required"

python3 - "$LOGS_DIR" "$JSON_OUTPUT" "$VERBOSE" "$COUNT" <<'PYEOF'
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from collections import Counter, defaultdict

logs_dir = Path(sys.argv[1])
json_output = sys.argv[2].lower() == "true"
verbose = sys.argv[3].lower() == "true"
count_limit = int(sys.argv[4])

def parse_ts(ts_str):
    if not ts_str:
        return None
    try:
        return datetime.fromisoformat(ts_str.replace('Z', '+00:00'))
    except (ValueError, AttributeError):
        return None

DIFF_RE = re.compile(r"PR review config:.*?\(diff:\s*(\d+)\s*lines")

def get_diff_lines(run_dir):
    """Parse the PR-review diff line count from orchestrator.log.

    The orchestrator logs e.g. `PR review config: model=sonnet, timeout=1200s,
    max_iter=2 (diff: 332 lines, profile: full)` immediately before launching
    PR review. We return the int N (or None if not found).
    """
    log_file = run_dir / "orchestrator.log"
    if not log_file.exists():
        return None
    try:
        with open(log_file, errors="replace") as f:
            for line in f:
                m = DIFF_RE.search(line)
                if m:
                    return int(m.group(1))
    except OSError:
        return None
    return None

def diff_bucket(n):
    """Bucket diff line counts to match orchestrator's get_pr_review_config thresholds."""
    if n is None:
        return "unknown"
    if n < 50:
        return "<50"
    if n < 200:
        return "<200"
    return "200+"

def get_events_iter_times(run_dir):
    """Extract per-iteration start timestamps from events.jsonl."""
    events_file = run_dir / "events.jsonl"
    if not events_file.exists():
        return {}
    data = {}
    with open(events_file) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            if ev.get("event") != "model_call":
                continue
            stage = ev.get("stage", "")
            ts = ev.get("ts", "")
            key = stage.replace("-", "_") + "_start"
            if key not in data:
                data[key] = parse_ts(ts)
    return data

def analyze_run(run_dir):
    metrics_file = run_dir / "metrics.json"
    if not metrics_file.exists():
        return None
    with open(metrics_file) as f:
        metrics = json.load(f)
    if metrics.get("state") != "completed":
        return None
    stages = metrics.get("stages", {})
    started_at = parse_ts(metrics.get("started_at"))
    if not started_at:
        return None

    r = {
        "run": run_dir.name,
        "issue": metrics.get("issue"),
        "total_s": metrics.get("total_duration_seconds"),
        "route": stages.get("triage", {}).get("route"),
        "pr_number": stages.get("pr", {}).get("pr_number"),
        "events": get_events_iter_times(run_dir),
        "diff_lines": get_diff_lines(run_dir),
    }
    r["diff_bucket"] = diff_bucket(r["diff_lines"])

    impl = stages.get("implement", {})
    r["implement_s"] = impl.get("duration_seconds")

    test_loop = stages.get("test_loop", {})
    test_start = parse_ts(test_loop.get("started_at"))
    if test_start:
        r["pre_test_s"] = (test_start - started_at).total_seconds()
        r["test_loop_s"] = test_loop.get("duration_seconds")
        r["test_iters"] = test_loop.get("iteration", 0)

    pr_rev = stages.get("pr_review", {})
    pr_rev_start = parse_ts(pr_rev.get("started_at"))
    if pr_rev_start:
        r["pre_pr_s"] = (pr_rev_start - started_at).total_seconds()
        r["pr_rev_s"] = pr_rev.get("duration_seconds")
        r["pr_rev_iters"] = pr_rev.get("iteration", 0)

    # PR-review first iteration breakdown from events
    ev = r["events"]
    if ev.get("pr_review_iter_1_start") and ev.get("fix_pr_review_iter_1_start"):
        r["pr_rev_iter1_review_s"] = (
            ev["fix_pr_review_iter_1_start"] - ev["pr_review_iter_1_start"]
        ).total_seconds()
    if ev.get("fix_pr_review_iter_1_start") and ev.get("pr_review_iter_2_start"):
        r["pr_rev_iter1_fix_s"] = (
            ev["pr_review_iter_2_start"] - ev["fix_pr_review_iter_1_start"]
        ).total_seconds()
    elif ev.get("fix_pr_review_iter_1_start") and pr_rev_start:
        pr_rev_end = parse_ts(pr_rev.get("completed_at"))
        if pr_rev_end:
            r["pr_rev_iter1_fix_s"] = (
                pr_rev_end - ev["fix_pr_review_iter_1_start"]
            ).total_seconds()

    return r

def pct(data, p):
    if not data:
        return None
    s = sorted(data)
    idx = min(int(len(s) * p / 100), len(s) - 1)
    return s[idx]

def stats_row(data, label):
    if not data:
        return None
    return {
        "label": label,
        "n": len(data),
        "min": min(data),
        "p50": pct(data, 50),
        "p75": pct(data, 75),
        "p90": pct(data, 90),
        "max": max(data),
    }

def fmt(v):
    if v is None: return "   -"
    return f"{v/60:5.1f}m"

def print_row(row):
    if not row:
        return
    print(f"  {row['label']:<40} n={row['n']:>3}  "
          f"p50={fmt(row['p50'])}  p75={fmt(row['p75'])}  "
          f"p90={fmt(row['p90'])}  max={fmt(row['max'])}")

# --- Collect runs ---
run_dirs = sorted(
    [d for d in logs_dir.iterdir() if d.is_dir() and (d / "metrics.json").exists()],
    key=lambda x: x.name
)
if count_limit > 0:
    run_dirs = run_dirs[-count_limit:]

runs = [r for d in run_dirs if (r := analyze_run(d)) is not None]

if verbose:
    print("\n=== PER-RUN DETAIL ===", file=sys.stderr)
    hdr = f"{'Run':<45} {'Total':>7} {'Impl':>7} {'Pre-Test':>9} {'TestL':>7} {'Pre-PR':>8} {'PR-Rev':>7} {'T-It':>5} {'P-It':>5}"
    print(hdr, file=sys.stderr)
    print("-" * len(hdr), file=sys.stderr)
    for r in runs:
        line = (f"{r['run']:<45} {fmt(r.get('total_s'))} {fmt(r.get('implement_s'))}"
                f" {fmt(r.get('pre_test_s')):>9} {fmt(r.get('test_loop_s')):>8}"
                f" {fmt(r.get('pre_pr_s')):>8} {fmt(r.get('pr_rev_s')):>7}"
                f" {str(r.get('test_iters','-')):>5} {str(r.get('pr_rev_iters','-')):>5}")
        print(line, file=sys.stderr)

# --- Compute stats ---
def vals(key): return [r[key] for r in runs if r.get(key) is not None]
def vals_gt(key, floor): return [v for v in vals(key) if v > floor]

results = {
    "implement":         stats_row(vals("implement_s"),     "Implement stage"),
    "pre_test":          stats_row(vals("pre_test_s"),      "Pre-test-loop wall time"),
    "pre_pr":            stats_row(vals("pre_pr_s"),        "Pre-PR-review wall time"),
    "test_loop_active":  stats_row(vals_gt("test_loop_s", 10), "Test loop (runs with >10s work)"),
    "pr_review":         stats_row(vals("pr_rev_s"),        "PR-review loop total"),
    "pr_rev_iter1":      stats_row(vals("pr_rev_iter1_review_s"), "PR-review iter-1 (review agent)"),
    "pr_rev_iter1_fix":  stats_row(vals("pr_rev_iter1_fix_s"),    "PR-review iter-1 (fix agent)"),
    "total":             stats_row(vals("total_s"),         "Total run duration"),
}

test_iter_counts = Counter(r.get("test_iters", 0) for r in runs if r.get("pre_test_s") is not None)
pr_iter_counts   = Counter(r.get("pr_rev_iters", 0) for r in runs if r.get("pre_pr_s") is not None)

# By-diff-size buckets for PR-review first iteration.
#
# When iteration == 1, the whole pr_review duration IS the iter-1 duration —
# this gives us a much larger sample than events.jsonl alone (which only
# carries per-iter timestamps for newer runs).
BUCKETS = ["<50", "<200", "200+", "unknown"]
by_bucket_iter1 = defaultdict(list)  # bucket -> [iter1 seconds]
by_bucket_review = defaultdict(list) # events-derived review-agent seconds
by_bucket_fix    = defaultdict(list) # events-derived fix-agent seconds
by_bucket_total  = defaultdict(list) # full pr_review loop seconds
for r in runs:
    b = r["diff_bucket"]
    if r.get("pr_rev_iters") == 1 and r.get("pr_rev_s") is not None:
        by_bucket_iter1[b].append(r["pr_rev_s"])
    if r.get("pr_rev_iter1_review_s") is not None:
        by_bucket_review[b].append(r["pr_rev_iter1_review_s"])
    if r.get("pr_rev_iter1_fix_s") is not None:
        by_bucket_fix[b].append(r["pr_rev_iter1_fix_s"])
    if r.get("pr_rev_s") is not None:
        by_bucket_total[b].append(r["pr_rev_s"])

def bucket_stats(d, label):
    out = {}
    for b in BUCKETS:
        if d.get(b):
            out[b] = stats_row(d[b], f"{label} [{b}]")
    return out

iter1_by_bucket   = bucket_stats(by_bucket_iter1,  "PR-review iter-1 (1-iter runs)")
review_by_bucket  = bucket_stats(by_bucket_review, "PR-review iter-1 review")
fix_by_bucket     = bucket_stats(by_bucket_fix,    "PR-review iter-1 fix")
total_by_bucket   = bucket_stats(by_bucket_total,  "PR-review loop total")

if json_output:
    output = {"runs_analyzed": len(runs), "stats": {}, "iteration_counts": {}, "by_diff_bucket": {}}
    for k, v in results.items():
        if v:
            output["stats"][k] = v
    output["iteration_counts"]["test_loop"] = dict(sorted(test_iter_counts.items()))
    output["iteration_counts"]["pr_review"] = dict(sorted(pr_iter_counts.items()))
    output["by_diff_bucket"]["iter1_1iter_runs"] = iter1_by_bucket
    output["by_diff_bucket"]["iter1_review_agent"] = review_by_bucket
    output["by_diff_bucket"]["iter1_fix_agent"] = fix_by_bucket
    output["by_diff_bucket"]["pr_review_total"] = total_by_bucket
    output["diff_bucket_counts"] = dict(Counter(r["diff_bucket"] for r in runs))
    print(json.dumps(output, indent=2))
else:
    print(f"\nanalyze-wall-time: {len(runs)} completed runs from {logs_dir.name}\n")

    print("PHASE WALL-TIMES  (all times in minutes)")
    print("=" * 80)
    for row in results.values():
        print_row(row)

    print()
    print("ITERATION COUNTS")
    print("=" * 80)
    print(f"  test_loop iterations : {dict(sorted(test_iter_counts.items()))}")
    print(f"  pr_review iterations : {dict(sorted(pr_iter_counts.items()))}")

    # By-diff-size breakdown — answers "what does iter-1 actually cost vs the
    # per-iter timeout that scales with diff size?" The orchestrator's
    # get_pr_review_config thresholds (<50 / <200 / 200+) drive both the iter
    # timeout and these buckets.
    bucket_counts = Counter(r["diff_bucket"] for r in runs)
    print()
    print("PR-REVIEW BY DIFF SIZE  (matches get_pr_review_config thresholds)")
    print("=" * 80)
    print(f"  diff_bucket counts: {dict((b, bucket_counts.get(b, 0)) for b in BUCKETS)}")
    print()
    print("  --- Iter-1 duration (1-iter runs: pr_review_s == iter-1 s) ---")
    for b in BUCKETS:
        row = iter1_by_bucket.get(b)
        if row:
            print_row(row)
    if review_by_bucket:
        print()
        print("  --- Iter-1 review agent (events.jsonl) ---")
        for b in BUCKETS:
            row = review_by_bucket.get(b)
            if row:
                print_row(row)
    if fix_by_bucket:
        print()
        print("  --- Iter-1 fix agent (events.jsonl) ---")
        for b in BUCKETS:
            row = fix_by_bucket.get(b)
            if row:
                print_row(row)
    print()
    print("  --- PR-review loop total (all iterations) by diff ---")
    for b in BUCKETS:
        row = total_by_bucket.get(b)
        if row:
            print_row(row)

    # Recommendations
    pre_pr_p90  = results["pre_pr"]["p90"]   if results["pre_pr"]  else None
    pr_rev_p90  = results["pr_review"]["p90"] if results["pr_review"] else None
    total_p90   = results["total"]["p90"]    if results["total"]   else None
    test_p90    = results["test_loop_active"]["p90"] if results["test_loop_active"] else None

    print()
    print("DATA-DRIVEN BUDGET RECOMMENDATIONS")
    print("=" * 80)
    if pre_pr_p90:
        slack = 1.25
        print(f"  Pre-PR wall time p90 = {pre_pr_p90/60:.0f}m  →  "
              f"overall cap floor ≥ {pre_pr_p90*slack/60:.0f}m  "
              f"(p90 × {slack})")
    if pr_rev_p90:
        slack = 1.25
        print(f"  PR-review loop   p90 = {pr_rev_p90/60:.0f}m  →  "
              f"pr_review budget ≥ {pr_rev_p90*slack/60:.0f}m  "
              f"(p90 × {slack})")
    if test_p90:
        slack = 1.25
        print(f"  Test loop (active) p90 = {test_p90/60:.0f}m  →  "
              f"test budget ≥ {test_p90*slack/60:.0f}m  "
              f"(p90 × {slack})")
    if total_p90:
        slack = 1.33
        print(f"  Total run        p90 = {total_p90/60:.0f}m  →  "
              f"orchestrator cap ≥ {total_p90*slack/60:.0f}m  "
              f"(p90 × {slack})")

    # Per-bucket pr_review budget — what does iter-1 actually cost per diff
    # size, and how does that compare to the per-iter timeout currently
    # configured in get_pr_review_config (<50→360s, <200→600s, 200+→1200s)?
    per_iter_timeout = {"<50": 360, "<200": 600, "200+": 1200}
    if iter1_by_bucket:
        print()
        print("  PR-review iter-1 cost vs configured per-iter timeout:")
        for b in ["<50", "<200", "200+"]:
            row = iter1_by_bucket.get(b)
            if not row:
                continue
            p90s = row["p90"]
            cfg = per_iter_timeout[b]
            print(f"    [{b:>5}]  iter-1 p90 = {p90s/60:5.1f}m  "
                  f"(per-iter timeout = {cfg/60:.0f}m, "
                  f"headroom = {(cfg - p90s)/60:+.1f}m, n={row['n']})")

    # Diff-size commentary
    iter_review_data = vals("pr_rev_iter1_review_s")
    if iter_review_data:
        print()
        print("PR-REVIEW FIRST ITERATION (from events.jsonl)")
        print("=" * 80)
        print(f"  n={len(iter_review_data)} runs with events data")
        print(f"  Review agent: p50={pct(iter_review_data,50)/60:.1f}m  "
              f"p90={pct(iter_review_data,90)/60:.1f}m  "
              f"max={max(iter_review_data)/60:.1f}m")
        fix_data = vals("pr_rev_iter1_fix_s")
        if fix_data:
            print(f"  Fix agent:    p50={pct(fix_data,50)/60:.1f}m  "
                  f"p90={pct(fix_data,90)/60:.1f}m  "
                  f"max={max(fix_data)/60:.1f}m")
        combo = [a + b for a, b in zip(
            sorted(iter_review_data)[:min(len(iter_review_data), len(fix_data) if fix_data else 0)],
            sorted(fix_data)[:min(len(iter_review_data), len(fix_data) if fix_data else 0)]
        )] if fix_data else []
        if combo:
            print(f"  Full iter (review+fix): p50={pct(combo,50)/60:.1f}m  "
                  f"p90={pct(combo,90)/60:.1f}m  max={max(combo)/60:.1f}m")

PYEOF
