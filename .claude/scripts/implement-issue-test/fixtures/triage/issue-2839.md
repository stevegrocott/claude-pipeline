# Remove premature `toBeVisible()` assertion from `beforeEach` in feedback spec

The `beforeEach` block in `playwright/feedback.spec.ts` calls
`expect(page.locator('#feedback-form')).toBeVisible()` before any navigation
has occurred. This produces a flaky failure when the test runner is cold.
The helper invoked later in the test (`openFeedbackReport`) already asserts
visibility correctly, so the premature assertion is redundant.

## Implementation Tasks

- **(S)** In `playwright/feedback.spec.ts`, delete line 27 (the
  `expect(page.locator('#feedback-form')).toBeVisible();` statement inside
  `beforeEach`). Leave the rest of the block untouched.

## Affected files
- `playwright/feedback.spec.ts`

## Acceptance criteria

- Line 27 deleted
- `npx playwright test playwright/feedback.spec.ts` passes
