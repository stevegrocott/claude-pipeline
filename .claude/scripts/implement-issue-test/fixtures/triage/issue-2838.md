# Reduce retry count and bump timeout in feedback-report E2E

`playwright/feedback-report.e2e.ts` currently retries each test 3 times with
a 30-second timeout. That gives a 90-second worst case per test and pushes
total runtime over the CI budget. Pattern used elsewhere in the suite:
`test.setTimeout(60_000)` with retry count 1.

## Implementation Tasks

- **(S)** At the top of `playwright/feedback-report.e2e.ts`:
  - Line 8: change `test.describe.configure({ retries: 3 })` to
    `test.describe.configure({ retries: 1 })`
  - Line 12: change `test.setTimeout(30_000)` to `test.setTimeout(60_000)`
  - Line 31: remove the inline `test.setTimeout(45_000)` override
  - Line 195: remove the inline `test.setTimeout(45_000)` override
  - Line 232: remove the inline `test.setTimeout(45_000)` override
  - Line 245: remove trailing whitespace
  - Line 250: remove trailing whitespace

Math: 7 lines edited across 1 file. New worst case per test: 120s (60s × 2
attempts) — within budget. Inline overrides at 31/195/232 are no longer
needed because the file-level value is now sufficient.

## Affected files
- `playwright/feedback-report.e2e.ts`

## Acceptance criteria

- Per-test worst-case runtime ≤120s
- All tests in the file still pass under the new config
