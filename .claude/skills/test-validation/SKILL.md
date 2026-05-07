---
name: test-validation
description: Use when tests need to be run and validated for quality — checks for hollow assertions, missing assertions, and commented-out tests in changed files
inputs:
  - name: test_command
    type: string
    required: true
    description: The test command to execute, provided in the invoking prompt
outputs:
  - name: result
    type: string
    description: Overall test outcome — "passed" or "failed"
  - name: validation_result
    type: string
    description: Validation outcome — "passed" or "failed" based on assertion quality checks
  - name: validation_issues
    type: json
    description: Array of hollow assertion, empty body, or commented-out test findings with file and line
side_effects:
  - runs_test_suite
composes: []
failure_modes:
  - id: test_command_fails
    mitigation: Report failure details (count, messages) and stop. Do not proceed to validation checks.
  - id: validation_issue_found
    mitigation: Report all findings in the structured JSON output. Do not fix the issues; report only.
---

# Test Validation

Run the test suite and validate test quality. Execute commands, check results, report findings — do not explore the codebase.

## Rules

1. **Run the test command provided in the prompt.** Report pass/fail with counts.
2. **Do NOT read implementation files.** You are validating tests, not understanding the code.
3. **Do NOT explore the repository** to find additional tests or check coverage. Only validate what the test command produces.
4. **Validation checks are specific** — see the checklist below. Do not invent additional criteria.
5. **If tests pass and validation passes, you are done.** Do not continue exploring for edge cases.

## Process

```
1. Run the test command from the prompt
2. Report: pass/fail, test count, failure details if any
3. If tests passed, run validation checks on changed test files only
4. Report structured results
```

**Target: 3-5 turns maximum.** Turn 1: run tests. Turn 2: read changed test files (if validation needed). Turns 3-4: report.

## Validation Checklist

Only check these items. Do not add your own criteria.

**For each changed test file:**

1. **No hollow assertions** — Every `expect()` / `assert` must check a meaningful value. Flag: `expect(true)`, `expect(result).toBeTruthy()` without checking the actual value, `$this->assertTrue(true)`.
2. **No commented-out tests** — Flag `// test(`, `// it(`, `/* test`, or `$this->markTestSkipped()` without explanation.
3. **Assertions present** — Each test function must contain at least one assertion. Flag empty test bodies.

**Do NOT check:**
- Coverage percentages (not available without instrumentation)
- Whether edge cases are covered (subjective)
- Whether tests match implementation (requires reading implementation files)
- Test naming conventions (style, not quality)

## Reporting

If tests pass and all validation checks pass:
```json
{
  "result": "passed",
  "validation_result": "passed",
  "validation_issues": []
}
```

If tests pass but validation finds issues:
```json
{
  "result": "passed",
  "validation_result": "failed",
  "validation_issues": [{"file": "path", "line": 42, "issue": "hollow assertion: expect(true)"}]
}
```

## Why This Skill Exists

Without this skill, the test validation agent interprets "validate test comprehensiveness" broadly — reading implementation files, checking coverage, and spending 15+ turns exploring. The validation checklist is intentionally narrow to prevent this.
