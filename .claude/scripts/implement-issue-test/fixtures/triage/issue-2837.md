# Fix stale selectors causing 9 E2E failures

A recent UI refactor renamed several DOM IDs and changed component
hierarchies. Nine E2E tests across four spec files now reference selectors
that no longer exist. Each spec needs a different selector update — there's
no single find-and-replace that fixes them all.

## Implementation Tasks

- **(M)** In `playwright/dashboard.spec.ts`, update 3 selectors:
  - `#main-chart` → `[data-testid="dashboard-chart"]`
  - `.kpi-card.revenue` → `[data-testid="kpi-revenue"]`
  - `button.refresh` → `[data-testid="dashboard-refresh"]`
  Verify each test still asserts the same behaviour as before — the
  selector change should not affect what's being tested.

- **(M)** In `playwright/reports.spec.ts`, the report list now uses a virtual
  scroller. The old approach of `page.locator('.report-row').nth(N)` no
  longer works because off-screen rows aren't rendered. Switch to filtering
  by visible text: `page.getByRole('row', { name: /report-N/ })`. Apply to
  3 tests.

- **(M)** In `playwright/admin.spec.ts`, the admin form was split into two
  panels. The old single-form locator needs to become two locators with
  separate `fill()` calls. Touches 2 tests.

- **(M)** In `playwright/settings.spec.ts`, the settings tabs were
  restructured. The "Notifications" tab is now under a "Preferences" group.
  Update the navigation step in 1 test.

## Affected files
- `playwright/dashboard.spec.ts`
- `playwright/reports.spec.ts`
- `playwright/admin.spec.ts`
- `playwright/settings.spec.ts`

## Acceptance criteria

- All 9 previously-failing E2E tests pass
- No regression in previously-passing tests
