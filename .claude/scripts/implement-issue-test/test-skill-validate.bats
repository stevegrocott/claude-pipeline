#!/usr/bin/env bats
#
# test-skill-validate.bats
# Tests for .claude/scripts/skill-validate.sh
#
# Covers:
#   (a) valid frontmatter passes
#   (b) missing required fields rejected
#   (c) malformed YAML rejected
#   (d) unknown top-level keys rejected
#
# Environment overrides used by skill-validate.sh:
#   SKILLS_DIR    — directory containing skill subdirectories
#                   (default: .claude/skills)
#   SKILL_SCHEMA  — path to the JSON schema file
#

load 'helpers/test-helper.bash'

# Resolved in setup() once SCRIPT_DIR and TEST_TMP are available.
SKILL_VALIDATE_SCRIPT=""
TEST_SKILLS_DIR=""
TEST_SCHEMA_FILE=""

setup() {
	setup_test_env

	SKILL_VALIDATE_SCRIPT="$SCRIPT_DIR/skill-validate.sh"
	TEST_SKILLS_DIR="$TEST_TMP/skills"
	TEST_SCHEMA_FILE="$TEST_TMP/schemas/skill-frontmatter.json"

	mkdir -p "$TEST_SKILLS_DIR"
	mkdir -p "$TEST_TMP/schemas"

	# Prefer the real schema when it exists; otherwise inline a minimal one so
	# the tests are self-contained even before task-1 is merged.
	if [[ -f "$SCRIPT_DIR/schemas/skill-frontmatter.json" ]]; then
		cp "$SCRIPT_DIR/schemas/skill-frontmatter.json" "$TEST_SCHEMA_FILE"
	else
		cat > "$TEST_SCHEMA_FILE" << 'SCHEMA_EOF'
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["name", "description"],
  "additionalProperties": false,
  "properties": {
    "name":          { "type": "string", "minLength": 1 },
    "description":   { "type": "string", "minLength": 1 },
    "argument-hint": { "type": "string" },
    "inputs": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["name", "type"],
        "additionalProperties": false,
        "properties": {
          "name":        { "type": "string" },
          "type":        { "type": "string" },
          "required":    { "type": "boolean" },
          "description": { "type": "string" }
        }
      }
    },
    "outputs": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["name", "type"],
        "additionalProperties": false,
        "properties": {
          "name":        { "type": "string" },
          "type":        { "type": "string" },
          "description": { "type": "string" }
        }
      }
    },
    "side_effects": {
      "type": "array",
      "items": { "type": "string" }
    },
    "composes": {
      "type": "array",
      "items": { "type": "string" }
    },
    "failure_modes": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["id", "mitigation"],
        "additionalProperties": false,
        "properties": {
          "id":         { "type": "string" },
          "mitigation": { "type": "string" }
        }
      }
    }
  }
}
SCHEMA_EOF
	fi

	export SKILLS_DIR="$TEST_SKILLS_DIR"
	export SKILL_SCHEMA="$TEST_SCHEMA_FILE"
}

teardown() {
	teardown_test_env
}

# ---------------------------------------------------------------------------
# Helper: write a skill directory + SKILL.md from a frontmatter string.
# Usage: make_skill <skill-name> <frontmatter-body>
# The frontmatter-body is written between the --- delimiters.
# ---------------------------------------------------------------------------
make_skill() {
	local name="$1"
	local body="$2"

	mkdir -p "$TEST_SKILLS_DIR/$name"
	printf -- '---\n%s\n---\n\n# %s\n' "$body" "$name" \
		> "$TEST_SKILLS_DIR/$name/SKILL.md"
}

# =============================================================================
# (a) VALID FRONTMATTER PASSES
# =============================================================================

@test "(a) minimal valid frontmatter — all required fields — exits 0" {
	# Schema required set was widened in #296 to name, description, inputs,
	# outputs, side_effects, composes, failure_modes — supply them all.
	make_skill "my-skill" \
		"name: my-skill
description: A minimal test skill
inputs:
  - name: target
    type: string
outputs:
  - name: result
    type: string
side_effects:
  - none
composes:
  - mcp-tools
failure_modes:
  - id: boom
    mitigation: surface the error"

	run bash "$SKILL_VALIDATE_SCRIPT" --skill my-skill
	[ "$status" -eq 0 ]
}

@test "(a) valid frontmatter with all known optional fields exits 0" {
	make_skill "full-skill" \
		"name: full-skill
description: A skill with every optional field populated
argument-hint: \"<target>\"
inputs:
  - name: target
    type: string
    required: true
    description: The target to act on
outputs:
  - name: result_url
    type: url
    description: URL of the created resource
side_effects:
  - creates_github_issue
composes:
  - mcp-tools
failure_modes:
  - id: auth_failure
    mitigation: surface the gh auth error and do not retry"

	run bash "$SKILL_VALIDATE_SCRIPT" --skill full-skill
	[ "$status" -eq 0 ]
}

@test "(a) --all exits 0 when every skill in SKILLS_DIR has valid frontmatter" {
	# All seven schema-required fields must be present per #296.
	local valid_body
	valid_body="inputs:
  - name: target
    type: string
outputs:
  - name: result
    type: string
side_effects:
  - none
composes:
  - mcp-tools
failure_modes:
  - id: boom
    mitigation: surface the error"

	make_skill "skill-alpha" "name: skill-alpha
description: First valid skill
$valid_body"
	make_skill "skill-beta" "name: skill-beta
description: Second valid skill
$valid_body"

	run bash "$SKILL_VALIDATE_SCRIPT" --all
	[ "$status" -eq 0 ]
}

# =============================================================================
# (b) MISSING REQUIRED FIELDS REJECTED
# =============================================================================

@test "(b) frontmatter missing 'name' is rejected with non-zero exit" {
	make_skill "no-name" "description: A skill that forgot to declare its name"

	run bash "$SKILL_VALIDATE_SCRIPT" --skill no-name 2>&1
	[ "$status" -ne 0 ]
}

@test "(b) error for missing 'name' mentions the field in output" {
	make_skill "no-name-msg" "description: A skill without a name field"

	run bash "$SKILL_VALIDATE_SCRIPT" --skill no-name-msg 2>&1
	[[ "$output" == *"name"* ]]
}

@test "(b) frontmatter missing 'description' is rejected with non-zero exit" {
	make_skill "no-desc" "name: no-desc"

	run bash "$SKILL_VALIDATE_SCRIPT" --skill no-desc 2>&1
	[ "$status" -ne 0 ]
}

@test "(b) error for missing 'description' mentions the field in output" {
	make_skill "no-desc-msg" "name: no-desc-msg"

	run bash "$SKILL_VALIDATE_SCRIPT" --skill no-desc-msg 2>&1
	[[ "$output" == *"description"* ]]
}

@test "(b) frontmatter missing 'side_effects' is rejected with non-zero exit" {
	make_skill "no-side-effects" \
		"name: no-side-effects
description: A skill missing the required side_effects field
inputs: []
outputs: []
composes: []
failure_modes: []"

	run bash "$SKILL_VALIDATE_SCRIPT" --skill no-side-effects 2>&1
	[ "$status" -ne 0 ]
}

@test "(b) empty frontmatter block is rejected" {
	mkdir -p "$TEST_SKILLS_DIR/empty-fm"
	printf -- '---\n---\n\n# Empty\n' > "$TEST_SKILLS_DIR/empty-fm/SKILL.md"

	run bash "$SKILL_VALIDATE_SCRIPT" --skill empty-fm 2>&1
	[ "$status" -ne 0 ]
}

@test "(b) --all exits non-zero when any skill is missing a required field" {
	make_skill "good-skill" "name: good-skill
description: This one is fine"
	make_skill "bad-skill" "description: No name field here"

	run bash "$SKILL_VALIDATE_SCRIPT" --all 2>&1
	[ "$status" -ne 0 ]
}

# =============================================================================
# (c) MALFORMED YAML REJECTED
# =============================================================================

@test "(c) unclosed quoted string in frontmatter is rejected" {
	local target="$TEST_SKILLS_DIR/bad-quote/SKILL.md"
	mkdir -p "$TEST_SKILLS_DIR/bad-quote"
	# Write the malformed frontmatter using printf so the literal
	# unclosed-quote string reaches the file unchanged.
	printf -- '%s\n' \
		'---' \
		'name: bad-quote' \
		'description: "unclosed string' \
		'---' \
		'' \
		'# Skill' > "$target"

	run bash "$SKILL_VALIDATE_SCRIPT" --skill bad-quote 2>&1
	[ "$status" -ne 0 ]
}

@test "(c) tab-indented block sequence in frontmatter is rejected" {
	local target="$TEST_SKILLS_DIR/tab-indent/SKILL.md"
	mkdir -p "$TEST_SKILLS_DIR/tab-indent"
	# YAML 1.1/1.2 forbids tabs as indentation (spec §6.1). Ruby's Psych parser
	# (the engine used by skill-validate.sh) enforces this and raises a
	# Psych::SyntaxError for tab-indented block sequences. If skill-validate.sh
	# is ever ported to a Python-based parser, note that PyYAML tolerates tabs
	# in some positions by default — the test would need to be re-evaluated.
	# The \t below must be a hard tab character, not spaces.
	printf -- '%s\n' \
		'---' \
		'name: tab-indent' \
		'description: test' \
		'composes:' \
		$'\t- mcp-tools' \
		'---' > "$target"

	run bash "$SKILL_VALIDATE_SCRIPT" --skill tab-indent 2>&1
	[ "$status" -ne 0 ]
}

@test "(c) SKILL.md with no frontmatter delimiters at all is rejected" {
	mkdir -p "$TEST_SKILLS_DIR/no-delimiters"
	printf -- '# My Skill\n\nJust prose, no frontmatter block present.\n' \
		> "$TEST_SKILLS_DIR/no-delimiters/SKILL.md"

	run bash "$SKILL_VALIDATE_SCRIPT" --skill no-delimiters 2>&1
	[ "$status" -ne 0 ]
}

@test "(c) SKILL.md referencing an undefined YAML anchor is rejected" {
	mkdir -p "$TEST_SKILLS_DIR/bad-anchor"
	printf -- '---\nname: bad-anchor\ndescription: *undefined_anchor\n---\n' \
		> "$TEST_SKILLS_DIR/bad-anchor/SKILL.md"

	run bash "$SKILL_VALIDATE_SCRIPT" --skill bad-anchor 2>&1
	[ "$status" -ne 0 ]
}

# =============================================================================
# (d) UNKNOWN TOP-LEVEL KEYS REJECTED
# =============================================================================

@test "(d) frontmatter with one unknown top-level key is rejected" {
	make_skill "unknown-key" "name: unknown-key
description: A skill with a rogue top-level field
mystery_field: should not be here"

	run bash "$SKILL_VALIDATE_SCRIPT" --skill unknown-key 2>&1
	[ "$status" -ne 0 ]
}

@test "(d) error for unknown key names the offending key in output" {
	make_skill "named-bad-key" "name: named-bad-key
description: Test skill
extra_metadata: this key is not in the schema"

	run bash "$SKILL_VALIDATE_SCRIPT" --skill named-bad-key 2>&1
	[[ "$output" == *"extra_metadata"* ]]
}

@test "(d) frontmatter with multiple unknown top-level keys is rejected" {
	make_skill "multi-unknown" "name: multi-unknown
description: Multiple unrecognised fields
foo: bar
baz: qux"

	run bash "$SKILL_VALIDATE_SCRIPT" --skill multi-unknown 2>&1
	[ "$status" -ne 0 ]
}

@test "(d) --all exits non-zero when any skill has an unknown top-level key" {
	make_skill "valid-in-batch" "name: valid-in-batch
description: This skill is fine"
	make_skill "invalid-in-batch" "name: invalid-in-batch
description: This skill has an unknown key
typo_field: oops"

	run bash "$SKILL_VALIDATE_SCRIPT" --all 2>&1
	[ "$status" -ne 0 ]
}

# =============================================================================
# (e) ISSUE #204 BATCH-1 INTEGRATION — validate 6 real Batch-1 skill files
#
# These tests use the actual SKILL.md files and the real schema.  They act as
# regression guards: if a later edit breaks a skill's frontmatter the suite
# will catch it without needing a separate manual run.
# =============================================================================

_real_skill_run() {
	local skill_name="$1"
	local real_skills="$SCRIPT_DIR/../skills"
	local real_schema="$SCRIPT_DIR/schemas/skill-frontmatter.json"

	run env \
		SKILLS_DIR="$real_skills" \
		SKILL_SCHEMA="$real_schema" \
		bash "$SKILL_VALIDATE_SCRIPT" --skill "$skill_name" 2>&1
}

@test "(e) issue-204 using-skills SKILL.md exits 0" {
	_real_skill_run using-skills
	[ "$status" -eq 0 ]
}

@test "(e) issue-204 writing-skills SKILL.md exits 0" {
	_real_skill_run writing-skills
	[ "$status" -eq 0 ]
}

@test "(e) issue-204 writing-plans SKILL.md exits 0" {
	_real_skill_run writing-plans
	[ "$status" -eq 0 ]
}

@test "(e) issue-204 writing-agents SKILL.md exits 0" {
	_real_skill_run writing-agents
	[ "$status" -eq 0 ]
}

@test "(e) issue-204 brainstorming SKILL.md exits 0" {
	_real_skill_run brainstorming
	[ "$status" -eq 0 ]
}

@test "(e) issue-204 adapting-claude-pipeline SKILL.md exits 0" {
	_real_skill_run adapting-claude-pipeline
	[ "$status" -eq 0 ]
}
