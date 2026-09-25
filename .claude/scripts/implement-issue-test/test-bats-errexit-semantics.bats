#!/usr/bin/env bats
#
# test-bats-errexit-semantics.bats
# Issue #909: helpers/test-helper.bash's expect_* rationale comment claimed a
# bare `[[ ... ]]` mid-body is silently ignored by bats, and that claim is
# false on bats 1.13.0 — measured, it fails the test. Only `! cmd` is
# genuinely inert mid-body. This probe pins the measured semantics as
# executable fact by running real fixtures through a nested `bats` process,
# so a future bats version bump that changes this behaviour fails this suite
# instead of silently invalidating the doc comment again.
#

bats_require_minimum_version 1.5.0

load 'helpers/test-helper.bash'

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

@test "AC3: a bare failing [[ ]] mid-body fails the test" {
	local f
	f=$(_fixture 'bare-bracket.bats' "$(printf '%s\n' \
		'@test "inner" {' \
		'	[[ "abc" == "xyz" ]]' \
		'	[[ "abc" == "abc" ]]' \
		'}')")

	run bats "$f"
	[[ "$status" -ne 0 ]] || fail "expected the nested bats run to fail, got status 0: $output"
	assert_contains "$output" "not ok 1"
}

@test "AC4: a negated command (! cmd) mid-body does NOT fail the test" {
	local f
	f=$(_fixture 'negated.bats' "$(printf '%s\n' \
		'@test "inner" {' \
		'	! true' \
		'	echo REACHED' \
		'}')")

	run bats "$f"
	[[ "$status" -eq 0 ]] || fail "expected the nested bats run to pass (! is errexit-exempt), got status $status: $output"
	assert_contains "$output" "ok 1"
}

@test "post-increment ((x++)) at x=0 fails the test" {
	local f
	f=$(_fixture 'post-increment.bats' "$(printf '%s\n' \
		'@test "inner" {' \
		'	local x=0' \
		'	((x++))' \
		'	echo "x is now $x"' \
		'}')")

	run bats "$f"
	[[ "$status" -ne 0 ]] || fail "expected the nested bats run to fail (x++ evaluates to the pre-increment 0, i.e. false), got status 0: $output"
	assert_contains "$output" "not ok 1"
}
