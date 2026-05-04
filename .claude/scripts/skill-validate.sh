#!/usr/bin/env bash
#
# skill-validate.sh — validate SKILL.md YAML frontmatter against schema
#
# Usage:
#   skill-validate.sh --skill <name>   validate one skill by directory name
#   skill-validate.sh --all            validate every skill in SKILLS_DIR
#
# Environment (both are overridable for testing):
#   SKILLS_DIR   — root of skill directories
#                  (default: ../skills relative to this script)
#   SKILL_SCHEMA — path to the JSON schema file
#                  (default: schemas/skill-frontmatter.json relative to
#                  this script)
#
# Exit codes:
#   0 — all validated skills passed
#   1 — one or more skills failed validation
#

set -o pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

SKILLS_DIR="${SKILLS_DIR:-"$SCRIPT_DIR/../skills"}"
SKILL_SCHEMA="${SKILL_SCHEMA:-"$SCRIPT_DIR/schemas/skill-frontmatter.json"}"

# ---------------------------------------------------------------------------
# die  — print error and exit 1
# ---------------------------------------------------------------------------
die() {
	printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2
	exit 1
}

# ---------------------------------------------------------------------------
# usage
# ---------------------------------------------------------------------------
usage() {
	cat <<EOF
Usage: $SCRIPT_NAME --skill <name>
       $SCRIPT_NAME --all

Validate SKILL.md YAML frontmatter against the JSON schema.

Options:
    --skill <name>   Validate one skill directory in SKILLS_DIR
    --all            Validate all skill directories in SKILLS_DIR
    -h, --help       Show this message

Environment:
    SKILLS_DIR       Root of skill directories
                     (default: \$SCRIPT_DIR/../skills)
    SKILL_SCHEMA     Path to the JSON schema
                     (default: \$SCRIPT_DIR/schemas/skill-frontmatter.json)
EOF
}

# ---------------------------------------------------------------------------
# _validate_file <skill_file>
#
# Validates one SKILL.md file using Ruby (built-in YAML + JSON support).
# Errors go to stderr.  Returns 0 on success, 1 on failure.
# ---------------------------------------------------------------------------
_validate_file() {
	local skill_file="$1"

	ruby - "$skill_file" "$SKILL_SCHEMA" 2>&1 <<'RUBYEOF'
require 'yaml'
require 'json'

skill_path  = ARGV[0]
schema_path = ARGV[1]

# ---- read SKILL.md -------------------------------------------------------
begin
  content = File.read(skill_path)
rescue SystemCallError => e
  $stderr.puts "ERROR: #{skill_path}: cannot read file: #{e.message}"
  exit 1
end

# ---- read schema ---------------------------------------------------------
begin
  schema = JSON.parse(File.read(schema_path))
rescue SystemCallError => e
  $stderr.puts "ERROR: cannot read schema #{schema_path}: #{e.message}"
  exit 1
rescue JSON::ParserError => e
  $stderr.puts "ERROR: invalid schema JSON: #{e.message}"
  exit 1
end

# ---- extract YAML frontmatter -------------------------------------------
# Matches the first ---...--- block, with \A anchoring to the string start
# and ^ matching line starts (Ruby's default multiline ^ / $).
m = content.match(/\A---[ \t]*\r?\n(.*?)^---[ \t]*\r?$/m)
unless m
  $stderr.puts(
    "ERROR: #{skill_path}: " \
    "no YAML frontmatter delimiters (---) found"
  )
  exit 1
end

fm_text = m[1]
if fm_text.strip.empty?
  $stderr.puts "ERROR: #{skill_path}: empty frontmatter block"
  exit 1
end

# ---- parse YAML ----------------------------------------------------------
begin
  data = Psych.safe_load(fm_text)
rescue Psych::Exception => e
  $stderr.puts(
    "ERROR: #{skill_path}: invalid YAML: #{e.message.lines.first.chomp}"
  )
  exit 1
end

unless data.is_a?(Hash)
  $stderr.puts(
    "ERROR: #{skill_path}: " \
    "frontmatter must be a YAML mapping (key: value pairs)"
  )
  exit 1
end

# ---- schema validation ---------------------------------------------------
required = schema.fetch('required', [])
allowed  = schema.fetch('properties', {}).keys

errors = []
required.each { |f| errors << "missing required field: '#{f}'" \
  unless data.key?(f) }
data.each_key { |k| errors << "unknown field: '#{k}'" \
  unless allowed.include?(k) }

if errors.any?
  errors.each { |e| $stderr.puts "ERROR: #{skill_path}: #{e}" }
  exit 1
end

exit 0
RUBYEOF
}

# ---------------------------------------------------------------------------
# validate_skill <name>
#
# Resolves SKILLS_DIR/<name>/SKILL.md and validates it.
# ---------------------------------------------------------------------------
validate_skill() {
	local name="$1"
	local skill_file="$SKILLS_DIR/$name/SKILL.md"

	if [[ ! -f "$skill_file" ]]; then
		printf 'ERROR: %s: SKILL.md not found\n' "$skill_file" >&2
		return 1
	fi

	_validate_file "$skill_file"
}

# ---------------------------------------------------------------------------
# validate_all
#
# Validates every SKILL.md found in SKILLS_DIR.
# Continues past individual failures; returns 1 if any skill failed.
# ---------------------------------------------------------------------------
validate_all() {
	local failed=0
	local dir skill_file

	for dir in "$SKILLS_DIR"/*/; do
		[[ -d "$dir" ]] || continue
		skill_file="${dir}SKILL.md"
		[[ -f "$skill_file" ]] || continue

		if ! _validate_file "$skill_file"; then
			failed=1
		fi
	done

	return "$failed"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
	local mode=""
	local skill_name=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
			--skill)
				[[ $# -ge 2 ]] || die "missing argument for --skill"
				mode="skill"
				skill_name="$2"
				shift 2
				;;
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
				break
				;;
		esac
	done

	[[ -n "$mode" ]] || die "missing --skill <name> or --all"
	[[ -f "$SKILL_SCHEMA" ]] || die "schema not found: $SKILL_SCHEMA"

	case "$mode" in
		skill)	validate_skill "$skill_name" ;;
		all)	validate_all ;;
	esac
}

main "$@"
