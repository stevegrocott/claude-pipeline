# Replace `quickLogin` with `storageState` in 2 E2E specs

The `quickLogin` helper logs in via the UI on every test, which is slow and
flaky. We've already migrated 5 spec files to use `storageState` from the
playwright auth fixture, but two laggards remain.

## Implementation Tasks

- **(S)** In `playwright/dashboard.spec.ts`, replace the `beforeEach` block at
  line 14-22 (which calls `quickLogin(page, 'dashboard-user@example.com')`)
  with `test.use({ storageState: '.auth/dashboard-user.json' })` at the top of
  the file. Remove the `quickLogin` import on line 3.
- **(S)** In `playwright/reports.spec.ts`, replace the `beforeEach` block at
  line 18-26 with `test.use({ storageState: '.auth/reports-user.json' })`.
  Remove the `quickLogin` import on line 4.

## Affected files
- `playwright/dashboard.spec.ts`
- `playwright/reports.spec.ts`

## Acceptance criteria

- Both specs run via `npx playwright test` without invoking the login UI
- No remaining `quickLogin` references in the two files
