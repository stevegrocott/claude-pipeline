# Add experimental `withRetry` wrapper to two flaky tests

Two playwright tests are flaky on CI. Wrap them in a new `withRetry`
helper that retries up to 5 times on AssertionError but not on other
errors. The helper doesn't exist yet — this is the first use site.

## Implementation Tasks

- **(S)** In `playwright/checkout.spec.ts`, line 88, wrap the existing
  `test('completes checkout', async ({ page }) => { ... })` body in a
  `withRetry(5, async () => { ... })` callback. Import `withRetry` from
  `playwright/utils/with-retry.ts`.

- **(S)** In `playwright/onboarding.spec.ts`, line 142, same change for the
  `test('completes onboarding', ...)` block.

- **(S)** Create `playwright/utils/with-retry.ts` exporting the `withRetry`
  helper. Inline 12-line implementation: retry the callback up to N times,
  re-throwing immediately on non-AssertionError.

## Affected files
- `playwright/checkout.spec.ts`
- `playwright/onboarding.spec.ts`
- `playwright/utils/with-retry.ts`

## Acceptance criteria

- Both tests use `withRetry`
- Helper works as documented
