#!/usr/bin/env bats
#
# test-lint-bats-negated.bats
# Issue #854: `! cmd` is exempt from errexit, so in a bats test body it only
# fails the test when it is the LAST command (bats takes the body's exit
# status). Anywhere else it is a hollow assertion that passes against unfixed
# code — which is how #847's first-draft acceptance test went green against
# code known to be broken.
#
# lint-test-assertions.sh already owns "hollow assertion" detection, but every
# existing rule is JS/TS-only, so this whole class was invisible to it.
#

bats_require_minimum_version 1.5.0

load 'helpers/test-helper.bash'

LINTER="$(cd "$SCRIPT_DIR" && pwd)/lint-test-assertions.sh"

setup() {
	setup_test_env
}

teardown() {
	teardown_test_env
}

# Writes a .bats fixture and returns its path.
_fixture() {
	local name="$1" content="$2"
	local path="$TEST_TMP/$name"

	printf '%s\n' "$content" > "$path"
	printf '%s' "$path"
}

# Runs the linter over a fixture and returns the findings for the new rule.
_negated_findings() {
	"$LINTER" "$1" 2>/dev/null \
		| jq -c '[.[] | select(.pattern == "bats-negated-assertion")]'
}

@test "AC1: flags a non-terminal negated assertion" {
	local f
	f=$(_fixture 'hollow.bats' "$(printf '%s\n' \
		'@test "example" {' \
		'	run some_command' \
		'	! grep -q "must not appear" "$out"' \
		'	[[ "$status" -eq 0 ]]' \
		'}')")

	run _negated_findings "$f"
	[[ "$status" -eq 0 ]] || fail "linter errored: $output"
	local count
	count=$(printf '%s' "$output" | jq 'length')
	[[ "$count" -eq 1 ]] \
		|| fail "expected 1 finding for a non-terminal '! grep', got $count: $output"
}

@test "AC1: the finding carries the established shape" {
	local f
	f=$(_fixture 'shape.bats' "$(printf '%s\n' \
		'@test "example" {' \
		'	! grep -q "nope" "$out"' \
		'	echo done' \
		'}')")

	run _negated_findings "$f"
	local finding
	finding=$(printf '%s' "$output" | jq -c '.[0]')
	assert_contains "$finding" '"pattern":"bats-negated-assertion"'
	# line/file/snippet/severity must all be present — the host UI and the
	# existing rules depend on this exact object shape.
	printf '%s' "$finding" | jq -e '.file and .line and .snippet and .severity' \
		>/dev/null || fail "finding is missing a required key: $finding"
}

@test "AC1: reports the line of the offending assertion" {
	local f
	f=$(_fixture 'lineno.bats' "$(printf '%s\n' \
		'@test "example" {' \
		'	! grep -q "nope" "$out"' \
		'	echo done' \
		'}')")

	run _negated_findings "$f"
	local line
	line=$(printf '%s' "$output" | jq -r '.[0].line')
	[[ "$line" -eq 2 ]] || fail "expected line 2, got $line"
}

@test "AC2: does not flag a terminal negated assertion" {
	local f
	f=$(_fixture 'terminal.bats' "$(printf '%s\n' \
		'@test "example" {' \
		'	run some_command' \
		'	! grep -q "must not appear" "$out"' \
		'}')")

	run _negated_findings "$f"
	local count
	count=$(printf '%s' "$output" | jq 'length')
	[[ "$count" -eq 0 ]] \
		|| fail "a terminal '! grep' does fail the test and must not be flagged: $output"
}

@test "AC2: does not flag the sanctioned if/fail form" {
	local f
	f=$(_fixture 'good.bats' "$(printf '%s\n' \
		'@test "example" {' \
		'	if grep -q "must not appear" "$out"; then' \
		'		fail "it appeared"' \
		'	fi' \
		'	[[ "$status" -eq 0 ]]' \
		'}')")

	run _negated_findings "$f"
	local count
	count=$(printf '%s' "$output" | jq 'length')
	[[ "$count" -eq 0 ]] || fail "false positive on the correct form: $output"
}

@test "AC2: does not flag a negation outside any test body" {
	local f
	f=$(_fixture 'outside.bats' "$(printf '%s\n' \
		'setup() {' \
		'	! grep -q "nope" "$out"' \
		'	echo still_setup' \
		'}' \
		'' \
		'@test "example" {' \
		'	[[ 1 -eq 1 ]]' \
		'}')")

	run _negated_findings "$f"
	local count
	count=$(printf '%s' "$output" | jq 'length')
	[[ "$count" -eq 0 ]] \
		|| fail "flagged a negation outside a @test body: $output"
}

@test "AC2: a trailing comment does not make an assertion look non-terminal" {
	local f
	f=$(_fixture 'comment.bats' "$(printf '%s\n' \
		'@test "example" {' \
		'	! grep -q "nope" "$out"' \
		'	# this comment is not a command' \
		'}')")

	run _negated_findings "$f"
	local count
	count=$(printf '%s' "$output" | jq 'length')
	[[ "$count" -eq 0 ]] \
		|| fail "a comment after the assertion is not a command: $output"
}

@test "AC1: flags each non-terminal negation in a multi-test file" {
	local f
	# Built line-by-line rather than as one multi-line literal: a `@test` at
	# column 0 inside this file would be picked up by bats' own test parser
	# and split THIS test in half, silently truncating the fixture.
	f=$(_fixture 'multi.bats' "$(printf '%s\n' \
		'@test "one" {' \
		'	! grep -q "a" "$out"' \
		'	echo tail' \
		'}' \
		'' \
		'@test "two" {' \
		'	! grep -q "b" "$out"' \
		'	echo tail' \
		'}' \
		'' \
		'@test "three" {' \
		'	! grep -q "c" "$out"' \
		'}')")

	run _negated_findings "$f"
	local count
	count=$(printf '%s' "$output" | jq 'length')
	[[ "$count" -eq 2 ]] \
		|| fail "expected 2 findings (third is terminal), got $count: $output"
}

@test "AC2: a non-bats file is not scanned by this rule" {
	local f
	f=$(_fixture 'notbats.sh' "$(printf '%s\n' \
		'some_function() {' \
		'	! grep -q "nope" "$out"' \
		'	echo tail' \
		'}')")

	run _negated_findings "$f"
	local count
	count=$(printf '%s' "$output" | jq 'length')
	[[ "$count" -eq 0 ]] || fail "scanned a non-.bats file: $output"
}

@test "AC5: the repo's own bats suites are clean of the pattern" {
	local suite_dir findings
	suite_dir="$(cd "$SCRIPT_DIR/implement-issue-test" && pwd)"

	findings=$("$LINTER" "$suite_dir"/*.bats 2>/dev/null \
		| jq '[.[] | select(.pattern == "bats-negated-assertion")] | length')

	[[ "$findings" -eq 0 ]] \
		|| fail "$findings hollow negated assertion(s) remain in the suite; run the linter for locations"
}
