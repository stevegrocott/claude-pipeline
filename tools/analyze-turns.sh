#!/usr/bin/env bash
#
# analyze-turns.sh — Report turns-used distribution per stage type
#
# Walks logs/implement-issue/*/stages/*.log, extracts num_turns from the
# Claude SDK result JSON in each stage log, and prints p50/p90/max for
# each stage class (simplify-*, fix-review-*, implement-task-*).
#
# Usage: analyze-turns.sh [options] [logs-dir]
#
# Arguments:
#   logs-dir    Root of the implement-issue log tree
#               (default: logs/implement-issue relative to repo root)
#
# Options:
#   -h, --help       Show this help message
#   -j, --json       Emit results as JSON instead of a human-readable table
#   -v, --verbose    Show per-file extraction details on stderr
#
# Exit codes:
#   0   Analysis completed (even if some files had no num_turns)
#   1   Bad arguments or python3 unavailable

set -o pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

die() {
	printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2
	exit 1
}

usage() {
	cat <<EOF
Usage: $SCRIPT_NAME [options] [logs-dir]

Report turns-used p50/p90/max for simplify-*, fix-review-*, implement-task-*
stage logs under logs-dir.

Options:
    -h, --help       Show this help message
    -j, --json       Emit results as JSON
    -v, --verbose    Print per-file extraction details on stderr

Arguments:
    logs-dir         Path to implement-issue log tree
                     (default: $REPO_ROOT/logs/implement-issue)
EOF
}

main() {
	local json_out=false
	local verbose=false
	local logs_dir=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
			-h|--help)
				usage
				exit 0
				;;
			-j|--json)
				json_out=true
				shift
				;;
			-v|--verbose)
				verbose=true
				shift
				;;
			--)
				shift
				break
				;;
			-*)
				die "unknown option: $1"
				;;
			*)
				break
				;;
		esac
	done

	if [[ $# -ge 1 ]]; then
		logs_dir="$1"
	else
		logs_dir="$REPO_ROOT/logs/implement-issue"
	fi

	[[ -d "$logs_dir" ]] || die "logs-dir does not exist: $logs_dir"

	command -v python3 >/dev/null 2>&1 || die "python3 is required"

	local verbose_flag="false"
	$verbose && verbose_flag="true"

	local json_flag="false"
	$json_out && json_flag="true"

	python3 - "$logs_dir" "$verbose_flag" "$json_flag" <<'PYEOF'
import os, re, json, sys
from collections import defaultdict

logs_dir   = sys.argv[1]
verbose    = sys.argv[2] == "true"
emit_json  = sys.argv[3] == "true"

STAGE_CLASSES = {
    "simplify":       re.compile(r"simplify"),
    "fix-review":     re.compile(r"fix-(?:pr-)?review"),
    "implement-task": re.compile(r"implement-task"),
}

data = defaultdict(list)
files_seen = 0
files_matched = 0

for root, dirs, files in os.walk(logs_dir):
    if os.path.basename(root) != "stages":
        continue
    for fname in sorted(files):
        if not fname.endswith(".log"):
            continue
        files_seen += 1
        # Normalise: strip leading "01-" prefix and "-iter-N" suffix
        stage = re.sub(r"^\d+-", "", fname[:-4])
        stage = re.sub(r"-iter-\d+$", "", stage)

        label = None
        for cls, pat in STAGE_CLASSES.items():
            if pat.search(stage):
                label = cls
                break
        if label is None:
            continue

        fpath = os.path.join(root, fname)
        with open(fpath) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("==="):
                    continue
                try:
                    obj = json.loads(line)
                    if "num_turns" in obj:
                        turns = obj["num_turns"]
                        data[label].append(turns)
                        files_matched += 1
                        if verbose:
                            print(f"  {label:>15}  {turns:>3}  {fpath}", file=sys.stderr)
                        break
                except json.JSONDecodeError:
                    continue

def percentile(vals, p):
    if not vals:
        return None
    s = sorted(vals)
    idx = (len(s) - 1) * p / 100.0
    lo = int(idx)
    hi = lo + 1
    if hi >= len(s):
        return float(s[lo])
    return s[lo] + (s[hi] - s[lo]) * (idx - lo)

results = {}
for label in ["implement-task", "simplify", "fix-review"]:
    vals = data[label]
    results[label] = {
        "n":   len(vals),
        "min": min(vals) if vals else None,
        "p50": round(percentile(vals, 50), 1) if vals else None,
        "p90": round(percentile(vals, 90), 1) if vals else None,
        "max": max(vals) if vals else None,
        "values": sorted(vals),
    }

if emit_json:
    print(json.dumps(results, indent=2))
else:
    print()
    print("=== Turns-Used Distribution by Stage Type ===")
    print(f"    (from {files_matched} stage logs across {files_seen} scanned)")
    print()
    print(f"  {'Stage':<18} {'N':>5}  {'Min':>4}  {'p50':>5}  {'p90':>5}  {'Max':>4}")
    print("  " + "-" * 50)
    for label in ["implement-task", "simplify", "fix-review"]:
        r = results[label]
        if r["n"] == 0:
            print(f"  {label:<18} {'0':>5}  {'—':>4}  {'—':>5}  {'—':>5}  {'—':>4}")
            continue
        print(f"  {label:<18} {r['n']:>5}  {r['min']:>4}  {r['p50']:>5.1f}  {r['p90']:>5.1f}  {r['max']:>4}")
    print()

    # Per-class value histogram
    for label in ["implement-task", "simplify", "fix-review"]:
        vals = results[label]["values"]
        if not vals:
            continue
        from collections import Counter
        counts = Counter(vals)
        max_count = max(counts.values())
        bar_width = 30
        print(f"  {label}:")
        for v in sorted(counts):
            bar = "█" * round(counts[v] / max_count * bar_width)
            print(f"    {v:>3} turns  {counts[v]:>3}x  {bar}")
        print()

    print("  Note: num_turns is capped by each run's --max-turns budget, so")
    print("  p90/Max understate true demand for runs that hit the cap (those")
    print("  escalate). Pile-ups at a value (e.g. simplify ~10, fix-review ~26")
    print("  or ~41) mark a budget ceiling, not the natural workload — size new")
    print("  budgets above the pile-up, not at the observed p90.")
    print()
PYEOF
}

main "$@"
