#!/usr/bin/env bash
#
# feedback-record.sh
# Append a structured JSONL feedback record to logs/feedback/<kind>.jsonl
#
# Invoked by the pipeline-feedback skill to record structured observations
# about classification or routing errors for offline analysis.
#
# Usage:
#   ./feedback-record.sh --kind <kind> --issue <issue> --observed <text> \
#       --expected <text> [--evidence <path>] [--notes <text>]
#
# Required:
#   --kind      One of: triage_misclassification prompt_regression
#               criterion_drift agent_misroute escalation_loop
#   --issue     Issue number or identifier (string)
#   --observed  What the pipeline actually did
#   --expected  What the pipeline should have done
#
# Optional:
#   --evidence  Relative path to a supporting log or artifact
#   --notes     Free-form context or reproduction steps
#
# Output:
#   logs/feedback/<kind>.jsonl  — one JSONL line appended per unique record
#
# Exit codes:
#   0 - Success (record appended, or duplicate skipped within 60s window)
#   1 - Validation failure (invalid kind, missing required field, write error)
#

set -uo pipefail

# =============================================================================
# CONSTANTS
# =============================================================================

readonly -a VALID_KINDS=(
	triage_misclassification
	prompt_regression
	criterion_drift
	agent_misroute
	escalation_loop
)

readonly IDEMPOTENT_WINDOW=60

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

KIND=""
ISSUE=""
OBSERVED=""
EXPECTED=""
EVIDENCE=""
NOTES=""

while [[ $# -gt 0 ]]; do
	case "$1" in
		--kind)
			KIND="${2:-}"
			shift 2
			;;
		--issue)
			ISSUE="${2:-}"
			shift 2
			;;
		--observed)
			OBSERVED="${2:-}"
			shift 2
			;;
		--expected)
			EXPECTED="${2:-}"
			shift 2
			;;
		--evidence)
			EVIDENCE="${2:-}"
			shift 2
			;;
		--notes)
			NOTES="${2:-}"
			shift 2
			;;
		*)
			printf 'ERROR: Unknown option: %s\n' "$1" >&2
			exit 1
			;;
	esac
done

# =============================================================================
# VALIDATION
# =============================================================================

if [[ -z "$KIND" ]]; then
	printf 'ERROR: --kind is required\n' >&2
	exit 1
fi

if [[ -z "$ISSUE" ]]; then
	printf 'ERROR: --issue is required\n' >&2
	exit 1
fi

if [[ -z "$OBSERVED" ]]; then
	printf 'ERROR: --observed is required\n' >&2
	exit 1
fi

if [[ -z "$EXPECTED" ]]; then
	printf 'ERROR: --expected is required\n' >&2
	exit 1
fi

# Validate kind against enum
kind_valid=false
for k in "${VALID_KINDS[@]}"; do
	if [[ "$KIND" == "$k" ]]; then
		kind_valid=true
		break
	fi
done

if [[ "$kind_valid" != "true" ]]; then
	printf 'ERROR: Invalid kind "%s". Valid kinds: %s\n' \
		"$KIND" "${VALID_KINDS[*]}" >&2
	exit 1
fi

# =============================================================================
# BUILD RECORD
# =============================================================================

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
JSONL_DIR="logs/feedback"
JSONL_FILE="${JSONL_DIR}/${KIND}.jsonl"

# Build compact JSON record; omit optional fields if empty
RECORD=$(jq -cn \
	--arg ts       "$TIMESTAMP" \
	--arg kind     "$KIND" \
	--arg issue    "$ISSUE" \
	--arg observed "$OBSERVED" \
	--arg expected "$EXPECTED" \
	--arg evidence "$EVIDENCE" \
	--arg notes    "$NOTES" \
	'{
		timestamp: $ts,
		kind:      $kind,
		issue:     $issue,
		observed:  $observed,
		expected:  $expected
	}
	+ (if $evidence != "" then {evidence_path: $evidence} else {} end)
	+ (if $notes    != "" then {notes: $notes}            else {} end)')

# =============================================================================
# IDEMPOTENCY CHECK
# =============================================================================

if [[ -f "$JSONL_FILE" ]]; then
	now_epoch=$(date -u +%s)

	while IFS= read -r existing; do
		[[ -n "$existing" ]] || continue

		rec_kind=$(printf '%s' "$existing" | jq -r '.kind     // empty' 2>/dev/null)
		rec_issue=$(printf '%s' "$existing" | jq -r '.issue    // empty' 2>/dev/null)
		rec_observed=$(printf '%s' "$existing" | jq -r '.observed // empty' 2>/dev/null)
		rec_expected=$(printf '%s' "$existing" | jq -r '.expected // empty' 2>/dev/null)
		rec_ts=$(printf '%s' "$existing" | jq -r '.timestamp // empty' 2>/dev/null)

		if [[ "$rec_kind"     == "$KIND"     && \
		      "$rec_issue"    == "$ISSUE"    && \
		      "$rec_observed" == "$OBSERVED" && \
		      "$rec_expected" == "$EXPECTED" ]]; then

			if [[ -n "$rec_ts" ]]; then
				# Parse timestamp to epoch — GNU date first, BSD date (macOS) fallback
				rec_epoch=$(date -u -d "$rec_ts" +%s 2>/dev/null \
					|| date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$rec_ts" +%s 2>/dev/null \
					|| printf '%s' '0')
				age=$(( now_epoch - rec_epoch ))
				if (( age >= 0 && age <= IDEMPOTENT_WINDOW )); then
					# Duplicate within window — exit without appending
					exit 0
				fi
			fi
		fi
	done < "$JSONL_FILE"
fi

# =============================================================================
# APPEND RECORD
# =============================================================================

mkdir -p "$JSONL_DIR"
printf '%s\n' "$RECORD" >> "$JSONL_FILE"
