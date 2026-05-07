#!/usr/bin/env bash
#
# skill-golden.sh — generalized golden test runner for decision skills
#
# Usage:
#   skill-golden.sh <skill-name>            run all fixtures for one skill
#   skill-golden.sh <skill-name> <fixture>  run single fixture by basename
#   skill-golden.sh --all                   run every skill with a manifest
#
# Golden test config is read from .claude/skills/<skill>/SKILL.md frontmatter:
#
#   golden:
#     model:       haiku
#     manifest:    .claude/skills/<skill>/golden.manifest.txt
#     fixture_dir: .claude/scripts/implement-issue-test/fixtures/<skill>
#     schema:      .claude/scripts/schemas/<skill>.json
#
# Paths in SKILL.md frontmatter are relative to the repository root.
#
# Prompt building: .claude/skills/<skill>/prompt-builder.sh is sourced when
# present; it must define a build_prompt() shell function that accepts the
# fixture body on $1 and prints the full Claude prompt on stdout.  Skills
# without a prompt-builder.sh are skipped with a warning so a partially-wired
# suite does not block CI.
#
# Discovery (--all): scans .claude/skills/*/golden.manifest.txt.  Skills that
# have a manifest but are missing other required config (schema, prompt builder)
# are skipped with a warning; only fixture-level failures propagate to exit 1.
#
# Environment:
#   SKILLS_DIR     root of skill directories
#                  (default: $SCRIPT_DIR/../skills relative to this script)
#   SG_CLAUDE_CLI  path to claude CLI (default: claude)
#
# Exit codes:
#   0 — all tested fixtures passed (skipped skills do not count as failures)
#   1 — at least one fixture failed
#   2 — setup / usage error
#

set -o pipefail

readonly SCRIPT_NAME="${0##*/}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)" || exit 2
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)" || exit 2
readonly SCRIPT_DIR REPO_ROOT

SKILLS_DIR="${SKILLS_DIR:-"$SCRIPT_DIR/../skills"}"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/skill-golden-lib.sh" || {
	printf '%s: cannot source skill-golden-lib.sh\n' "$SCRIPT_NAME" >&2
	exit 2
}

# ---------------------------------------------------------------------------
# die — print error to stderr and exit 2
# ---------------------------------------------------------------------------
die() {
	printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2
	exit 2
}

# ---------------------------------------------------------------------------
# usage
# ---------------------------------------------------------------------------
usage() {
	cat <<EOF
Usage: $SCRIPT_NAME <skill-name> [fixture]
       $SCRIPT_NAME --all

Run real-Claude golden tests for decision skills.

Arguments:
    <skill-name>    Skill directory name under .claude/skills/
    <fixture>       Optional: run only this fixture basename (no extension)
    --all           Discover and run all skills with golden.manifest.txt

Environment:
    SKILLS_DIR      Root of skill directories
                    (default: \$SCRIPT_DIR/../skills)
    SG_CLAUDE_CLI   Path to claude CLI (default: claude)

Exit codes:
    0   all tested fixtures passed; skipped skills do not count as failures
    1   at least one fixture failed
    2   setup error (missing skill, manifest, schema, or usage error)
EOF
}

# ---------------------------------------------------------------------------
# read_golden_field SKILL_FILE FIELD
#
# Extracts one field from the golden: block of a SKILL.md YAML frontmatter.
# Prints the value on stdout. Exits (Ruby) 1 if the field is absent or the
# file / frontmatter cannot be parsed — bash callers treat a non-zero exit
# as "field not present" and keep the default.
# ---------------------------------------------------------------------------
read_golden_field() {
	local skill_file="$1"
	local field="$2"

	ruby - "$skill_file" "$field" 2>/dev/null <<'RUBYEOF'
require 'yaml'
content = File.read(ARGV[0]) rescue exit(1)
m = content.match(/\A---[ \t]*\r?\n(.*?)^---[ \t]*\r?$/m)
exit(1) unless m
begin
  data = Psych.safe_load(m[1])
rescue
  exit(1)
end
exit(1) unless data.is_a?(Hash)
golden = data['golden']
exit(1) unless golden.is_a?(Hash)
val = golden[ARGV[1]]
exit(1) if val.nil?
print val.to_s
RUBYEOF
}

# ---------------------------------------------------------------------------
# resolve_path RAW
#
# Turns a repo-root-relative path from SKILL.md frontmatter into an absolute
# path.  Absolute paths are returned unchanged.
# ---------------------------------------------------------------------------
resolve_path() {
	local raw="$1"
	case "$raw" in
		/*) printf '%s' "$raw" ;;
		*)  printf '%s/%s' "$REPO_ROOT" "$raw" ;;
	esac
}

# ---------------------------------------------------------------------------
# parse_manifest MANIFEST_FILE
#
# Reads manifest entries from MANIFEST_FILE, skipping blank lines and lines
# whose first non-whitespace character is '#'.  Prints one entry per line.
# ---------------------------------------------------------------------------
parse_manifest() {
	local file="$1"
	local line
	while IFS= read -r line; do
		[[ "$line" =~ ^[[:space:]]*$ ]]  && continue
		[[ "$line" =~ ^[[:space:]]*'#' ]] && continue
		printf '%s\n' "$line"
	done < "$file"
}

# ---------------------------------------------------------------------------
# run_skill SKILL_NAME [FILTER]
#
# Resolves the golden test config for SKILL_NAME, sources its prompt builder,
# and dispatches to sg_run_manifest from skill-golden-lib.sh.
#
# Returns:
#   0 — all fixtures passed (or skill skipped with a warning)
#   1 — at least one fixture failed
#   2 — configuration / setup error
# ---------------------------------------------------------------------------
run_skill() {
	local skill_name="$1"
	local filter="${2:-}"

	local manifest_file="$SKILLS_DIR/$skill_name/golden.manifest.txt"
	if [[ ! -f "$manifest_file" ]]; then
		printf '%s: no golden.manifest.txt for skill: %s\n' \
			"$SCRIPT_NAME" "$skill_name" >&2
		return 2
	fi

	# ------------------------------------------------------------------
	# Resolve config from SKILL.md frontmatter where present; fall back
	# to conventions for any field that is not specified.
	# ------------------------------------------------------------------
	local model fixture_dir schema
	model="haiku"
	fixture_dir="$SCRIPT_DIR/implement-issue-test/fixtures/$skill_name"
	schema=""

	local skill_md="$SKILLS_DIR/$skill_name/SKILL.md"
	if [[ -f "$skill_md" ]]; then
		local fm_model fm_fixture_dir fm_schema
		fm_model=$(read_golden_field "$skill_md" "model")       || fm_model=""
		fm_fixture_dir=$(read_golden_field "$skill_md" "fixture_dir") \
			|| fm_fixture_dir=""
		fm_schema=$(read_golden_field "$skill_md" "schema")     || fm_schema=""

		[[ -n "$fm_model" ]]       && model="$fm_model"
		[[ -n "$fm_fixture_dir" ]] && fixture_dir="$(resolve_path "$fm_fixture_dir")"
		[[ -n "$fm_schema" ]]      && schema="$(resolve_path "$fm_schema")"
	fi

	# Convention fallback: schemas/<skill-name>.json
	if [[ -z "$schema" ]]; then
		local candidate="$SCRIPT_DIR/schemas/$skill_name.json"
		[[ -f "$candidate" ]] && schema="$candidate"
	fi

	if [[ -z "$schema" ]]; then
		printf '%s: no schema found for skill: %s\n' \
			"$SCRIPT_NAME" "$skill_name" >&2
		printf '%s: add golden.schema to %s/SKILL.md or create %s\n' \
			"$SCRIPT_NAME" "$skill_name" \
			"$SCRIPT_DIR/schemas/$skill_name.json" >&2
		return 2
	fi

	# ------------------------------------------------------------------
	# Source the skill's prompt builder.  Without it we cannot invoke
	# Claude.  Return 2 (setup error) so direct invocations get a
	# non-zero exit and --all mode counts the skill as skipped (not
	# failed), keeping partial-wired suites from blocking CI.
	# ------------------------------------------------------------------
	local prompt_builder_file="$SKILLS_DIR/$skill_name/prompt-builder.sh"
	if [[ ! -f "$prompt_builder_file" ]]; then
		printf '%s: [SKIP] %s — no prompt-builder.sh\n' \
			"$SCRIPT_NAME" "$skill_name" >&2
		return 2
	fi

	# Clear any previous build_prompt from a prior skill in --all mode.
	unset -f build_prompt 2>/dev/null || true

	# shellcheck source=/dev/null
	source "$prompt_builder_file" || {
		printf '%s: failed to source prompt-builder.sh for: %s\n' \
			"$SCRIPT_NAME" "$skill_name" >&2
		return 2
	}

	if ! declare -F build_prompt >/dev/null 2>&1; then
		printf '%s: prompt-builder.sh for %s must define build_prompt()\n' \
			"$SCRIPT_NAME" "$skill_name" >&2
		return 2
	fi

	# ------------------------------------------------------------------
	# Parse manifest entries.
	# ------------------------------------------------------------------
	local -a entries
	while IFS= read -r entry; do
		entries+=("$entry")
	done < <(parse_manifest "$manifest_file")

	if ((${#entries[@]} == 0)); then
		printf '%s: manifest has no entries for skill: %s\n' \
			"$SCRIPT_NAME" "$skill_name" >&2
		return 2
	fi

	# ------------------------------------------------------------------
	# Setup check (jq, claude CLI, schema path, fixture dir) then run.
	# ------------------------------------------------------------------
	sg_check_setup "$fixture_dir" "$schema" || return 2

	sg_run_manifest \
		"$fixture_dir" "$schema" "$model" \
		build_prompt "$filter" \
		"${entries[@]}"
}

# ---------------------------------------------------------------------------
# run_all
#
# Discovers every skill that has a golden.manifest.txt file and runs each.
# Skills that are not fully configured (missing prompt-builder.sh, missing
# schema) are skipped with a warning and do not affect the overall exit code.
# ---------------------------------------------------------------------------
run_all() {
	local -a skills
	local manifest

	for manifest in "$SKILLS_DIR"/*/golden.manifest.txt; do
		[[ -f "$manifest" ]] || continue
		skills+=("$(basename "$(dirname "$manifest")")")
	done

	if ((${#skills[@]} == 0)); then
		printf '%s: no skills with golden.manifest.txt found in: %s\n' \
			"$SCRIPT_NAME" "$SKILLS_DIR" >&2
		return 2
	fi

	printf 'skill-golden: discovered %d skill(s): %s\n' \
		"${#skills[@]}" "${skills[*]}"
	printf '\n'

	local overall=0 total=0 failed=0 skipped=0
	local skill rc
	for skill in "${skills[@]}"; do
		printf '==> %s\n' "$skill"
		total=$((total + 1))

		run_skill "$skill"
		rc=$?

		if ((rc == 1)); then
			failed=$((failed + 1))
			overall=1
		elif ((rc == 2)); then
			skipped=$((skipped + 1))
		fi

		printf '\n'
	done

	printf 'skill-golden: %d skill(s) — %d failed, %d skipped\n' \
		"$total" "$failed" "$skipped"

	return "$overall"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
	local mode=""
	local skill_name=""
	local filter=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
			--all)
				mode="all"
				shift
				;;
			-h|--help)
				usage
				exit 0
				;;
			--)
				shift
				break
				;;
			-*)
				die "unknown option: $1"
				;;
			*)
				if [[ -z "$skill_name" ]]; then
					skill_name="$1"
					mode="skill"
				elif [[ -z "$filter" ]]; then
					filter="$1"
				else
					die "unexpected argument: $1"
				fi
				shift
				;;
		esac
	done

	[[ -n "$mode" ]] || die "specify <skill-name> or --all"

	case "$mode" in
		skill) run_skill "$skill_name" "$filter" ;;
		all)   run_all ;;
	esac
}

main "$@"
