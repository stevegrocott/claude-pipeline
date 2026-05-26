#!/usr/bin/env bats
#
# tests/lint-test-assertions.bats
# Tests for .claude/scripts/lint-test-assertions.sh (issue #370 task 5).
#
# The linter is a deterministic bash regex scanner that surfaces three
# hollow-assertion patterns observed in production PR-review escapes:
#
#   1. mock-timing perf — a `performance.now()` delta is compared via
#      `toBeLessThan(<ms>)` in a file that also calls `jest.mock`
#      (or `vi.mock`); the timed code is a mock so the threshold is
#      unfalsifiable.
#   2. constant-arithmetic — `expect(<constant expr>).toBe(<constant>)`
#      asserts arithmetic, not behaviour.
#   3. self-referential matcher — `expect(X.field).toBe(Y.field)` where
#      both sides derive from the same source, so the assertion can
#      pass while both are wrong.
#
# Each pattern is paired with a false-negative case the linter must NOT
# flag:
#
#   * a legitimate `performance.now()` test against non-mocked code
#   * arithmetic involving a real function call (not just constants)
#   * a matcher comparing two values from distinct sources
#
# The LINT_TEST_ASSERTIONS=0 env-var disable gate is exercised
# end-to-end: with the gate off, even a file that hits all three
# true-positive patterns must produce an empty JSON array.
#
# Acceptance criteria covered (issue #370):
#   AC1 — true-positive detection for each of the three patterns
#   AC2 — empty array on legitimate-only files (three false-negative cases)
#   AC5 — LINT_TEST_ASSERTIONS=0 disables the linter
#   AC6 — this file covers the three positives, three negatives, and the gate
#

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
LINTER="$REPO_ROOT/.claude/scripts/lint-test-assertions.sh"

# ---------------------------------------------------------------------------
# Per-test setup / teardown
# ---------------------------------------------------------------------------

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	# Default to gate ON so each test exercises real behaviour; the
	# disable-gate test opts out explicitly via env override on `run`.
	unset LINT_TEST_ASSERTIONS
}

teardown() {
	if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Write a fixture file inside TEST_TMP and echo its absolute path.  The
# fixture body is read from stdin so callers can use a heredoc without
# worrying about quoting `expect(...)` calls.
_write_fixture() {
	local name="$1"
	local path="$TEST_TMP/$name"
	cat > "$path"
	printf '%s\n' "$path"
}

# Assert that $output (from `run`) parses as a JSON array.  Returns
# non-zero on parse failure with a useful FAIL message.
_assert_json_array() {
	if ! printf '%s' "$output" | jq -e 'type == "array"' >/dev/null 2>&1; then
		printf 'FAIL: stdout is not a JSON array\n' >&2
		printf 'Full stdout: %s\n' "$output" >&2
		return 1
	fi
}

# Assert that the JSON array on stdout contains at least one finding
# whose .pattern equals $1.  Used by the three true-positive tests.
_assert_pattern_found() {
	local want="$1"
	local count
	count=$(printf '%s' "$output" \
		| jq --arg p "$want" '[.[] | select(.pattern == $p)] | length')
	if [[ "$count" -lt 1 ]]; then
		printf 'FAIL: expected at least one finding with pattern=%s\n' \
			"$want" >&2
		printf 'Full stdout: %s\n' "$output" >&2
		return 1
	fi
}

# Assert the JSON array is empty — used by the three false-negative
# tests and the env-var disable gate.
_assert_empty_array() {
	local len
	len=$(printf '%s' "$output" | jq 'length' 2>/dev/null)
	if [[ "$len" != "0" ]]; then
		printf 'FAIL: expected empty array, got length=%s\n' "$len" >&2
		printf 'Full stdout: %s\n' "$output" >&2
		return 1
	fi
}

# Assert the JSON array on stdout has zero entries with the given
# .pattern value.  Lets the env-gate test prove a previously-flagged
# fixture is no longer flagged.
_assert_no_pattern() {
	local want="$1"
	local count
	count=$(printf '%s' "$output" \
		| jq --arg p "$want" '[.[] | select(.pattern == $p)] | length')
	if [[ "$count" -ne 0 ]]; then
		printf 'FAIL: expected zero findings with pattern=%s, got %s\n' \
			"$want" "$count" >&2
		printf 'Full stdout: %s\n' "$output" >&2
		return 1
	fi
}

# Guard for every test: the script must exist and be executable.
# Until task 1 of issue #370 lands the file is absent; failing here
# RED is intentional (TDD discipline).
_require_linter() {
	if [[ ! -f "$LINTER" ]]; then
		printf 'RED: %s does not exist yet (task 1 not merged)\n' \
			"$LINTER" >&2
		return 1
	fi
}

# ===========================================================================
# TRUE POSITIVES — one test per documented pattern (AC1)
# ===========================================================================

@test "(1a) flags mock-timing perf threshold in a jest.mock'd file" {
	_require_linter

	local fixture
	fixture=$(_write_fixture "mock-timing.test.ts" <<'FIXTURE'
import { fetchUser } from "../src/api";

jest.mock("../src/api");

test("fetchUser resolves within budget", async () => {
	const start = performance.now();
	await fetchUser("u1");
	const delta = performance.now() - start;
	expect(delta).toBeLessThan(200);
});
FIXTURE
)

	run bash "$LINTER" "$fixture"
	[ "$status" -eq 0 ]
	_assert_json_array
	_assert_pattern_found "mock-timing-perf"
}

@test "(1b) flags constant-arithmetic tautology (numeric)" {
	_require_linter

	local fixture
	fixture=$(_write_fixture "const-arith.test.ts" <<'FIXTURE'
test("divides cleanly", () => {
	expect(30000 / 5).toBe(6000);
});
FIXTURE
)

	run bash "$LINTER" "$fixture"
	[ "$status" -eq 0 ]
	_assert_json_array
	_assert_pattern_found "constant-arithmetic"
}

@test "(1c) flags self-referential matcher (.field === .field)" {
	_require_linter

	local fixture
	fixture=$(_write_fixture "self-ref.test.ts" <<'FIXTURE'
test("same threshold", () => {
	const result1 = compute({ seed: 1 });
	const result2 = compute({ seed: 1 });
	expect(result1.userThreshold).toBe(result2.userThreshold);
});
FIXTURE
)

	run bash "$LINTER" "$fixture"
	[ "$status" -eq 0 ]
	_assert_json_array
	_assert_pattern_found "self-referential-matcher"
}

# ===========================================================================
# FALSE NEGATIVES — legitimate patterns must NOT be flagged (AC2)
# ===========================================================================

@test "(2a) does NOT flag a legitimate perf test (no jest.mock)" {
	_require_linter

	# No jest.mock/vi.mock in this file, so the two-signal heuristic
	# from issue #370 must not flag a real perf assertion.
	local fixture
	fixture=$(_write_fixture "real-perf.test.ts" <<'FIXTURE'
import { sortLargeArray } from "../src/sort";

test("sortLargeArray under budget", () => {
	const data = Array.from({ length: 50000 }, () => Math.random());
	const start = performance.now();
	sortLargeArray(data);
	const delta = performance.now() - start;
	expect(delta).toBeLessThan(200);
});
FIXTURE
)

	run bash "$LINTER" "$fixture"
	[ "$status" -eq 0 ]
	_assert_json_array
	_assert_no_pattern "mock-timing-perf"
}

@test "(2b) does NOT flag arithmetic involving a function call" {
	_require_linter

	# The left-hand side of the expect is dynamic (calls computeRate),
	# so this asserts behaviour, not arithmetic identity.
	local fixture
	fixture=$(_write_fixture "dynamic-arith.test.ts" <<'FIXTURE'
import { computeRate } from "../src/rate";

test("computeRate scales linearly", () => {
	expect(computeRate(30000) / 5).toBe(6000);
});
FIXTURE
)

	run bash "$LINTER" "$fixture"
	[ "$status" -eq 0 ]
	_assert_json_array
	_assert_no_pattern "constant-arithmetic"
}

@test "(2c) does NOT flag a matcher comparing distinct sources" {
	_require_linter

	# `actual` and `expected` come from different inputs / fixtures, so
	# the assertion has a concrete reference value — not self-referential.
	local fixture
	fixture=$(_write_fixture "distinct-sources.test.ts" <<'FIXTURE'
import { compute } from "../src/compute";
import expectedSnapshot from "./fixtures/expected.json";

test("compute matches snapshot", () => {
	const actual = compute({ seed: 1 });
	expect(actual.userThreshold).toBe(expectedSnapshot.userThreshold);
});
FIXTURE
)

	run bash "$LINTER" "$fixture"
	[ "$status" -eq 0 ]
	_assert_json_array
	_assert_no_pattern "self-referential-matcher"
}

# ===========================================================================
# ENV-VAR DISABLE GATE (AC5)
# ===========================================================================

@test "(3) LINT_TEST_ASSERTIONS=0 disables the linter; output is []" {
	_require_linter

	# Compose a fixture that hits ALL three positives simultaneously —
	# under the default gate this would produce >=3 findings.  With the
	# gate disabled the script must short-circuit to an empty array so
	# the orchestrator can rely on a single contract.
	local fixture
	fixture=$(_write_fixture "all-three.test.ts" <<'FIXTURE'
import { fetchUser, compute } from "../src/api";

jest.mock("../src/api");

test("mock-timing", async () => {
	const start = performance.now();
	await fetchUser("u1");
	expect(performance.now() - start).toBeLessThan(200);
});

test("constant arithmetic", () => {
	expect(30000 / 5).toBe(6000);
});

test("self-referential", () => {
	const a = compute({ seed: 1 });
	const b = compute({ seed: 1 });
	expect(a.userThreshold).toBe(b.userThreshold);
});
FIXTURE
)

	LINT_TEST_ASSERTIONS=0 run bash "$LINTER" "$fixture"
	[ "$status" -eq 0 ]
	_assert_json_array
	_assert_empty_array
}

# ===========================================================================
# Sanity: no input files → empty array, exit 0
# ===========================================================================

@test "(4) no fixture arguments → empty array, exit 0" {
	_require_linter

	run bash "$LINTER"
	[ "$status" -eq 0 ]
	_assert_json_array
	_assert_empty_array
}
