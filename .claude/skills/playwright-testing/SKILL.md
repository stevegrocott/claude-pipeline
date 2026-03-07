---
name: playwright-testing
description: Use when writing, reviewing, or debugging Playwright E2E tests. Use when converting manual test scripts to automated tests. Use when test failures involve browser interaction, page navigation, or UI assertions.
---

# Playwright Testing

## Overview

Conventions and patterns for writing reliable, maintainable Playwright E2E tests. Follow these patterns to avoid flaky tests, improve readability, and integrate with the project's TDD workflow.

## Page Object Model (POM)

One POM class per page or significant component. POMs encapsulate selectors and actions; assertions live in test files.

```typescript
// pages/login.page.ts
export class LoginPage {
  constructor(private page: Page) {}

  async goto() { await this.page.goto('/login'); }
  async login(user: string, pass: string) {
    await this.page.getByLabel('Username').fill(user);
    await this.page.getByLabel('Password').fill(pass);
    await this.page.getByRole('button', { name: 'Log in' }).click();
    return new DashboardPage(this.page);
  }
}
```

**Rules:**
- Constructor takes `page` fixture
- Navigation methods return new POM instances (e.g., `login()` returns `DashboardPage`)
- Assertions live in test files, not POMs
- POMs do actions, tests do assertions

## Selector Strategy

Priority order — use the most resilient selector available:

1. `data-testid` attributes — most resilient to UI changes
2. Role-based: `getByRole('button', { name: 'Submit' })`
3. Label-based: `getByLabel('Email')`
4. Text-based: `getByText('Welcome')` — for content assertions
5. CSS selectors — last resort, document why in a comment
6. **Never** XPath

## Waiting Patterns

Prefer Playwright's built-in auto-waiting. Explicit waits only when genuinely needed.

- `click`, `fill`, `expect` — all auto-wait by default
- `waitForResponse(resp => resp.url().includes('/api/...'))` — for API calls
- `expect(locator).toBeVisible()` — not manual `isVisible()` checks
- `page.waitForLoadState('networkidle')` — sparingly, only when genuinely needed

**Anti-pattern:** `page.waitForTimeout()` — always replace with condition-based waiting. Reference the `systematic-debugging/condition-based-waiting.md` technique.

## Test Data Management

- Seed via API or database before tests, never via UI
- Each test sets up its own state — no test interdependence
- `test.beforeEach` for shared setup within a describe block
- Clean up in `test.afterEach` or `test.afterAll` where practical

## Parallel Execution and Isolation

- Tests run in isolated browser contexts by default — don't fight this
- Avoid shared cookies, localStorage, or global state between tests
- `test.describe.serial` only when order genuinely matters (rare)

## Anti-Patterns

| Anti-pattern | Why it fails | Fix |
|---|---|---|
| `page.waitForTimeout(5000)` | Arbitrary delay, flaky in CI | Use `waitForResponse`, `expect(...).toBeVisible()`, or condition polling |
| `.css-1a2b3c` selectors | Break on any style change | Use `data-testid` or role-based selectors |
| Test B depends on Test A | Parallel execution breaks it | Each test sets up its own state |
| Assertions in page objects | Hides test intent, hard to debug | POMs do actions, tests do assertions |
| `page.$(selector)` | Doesn't auto-wait | Use `page.locator(selector)` or `getBy*` methods |
| Screenshot comparison without baselines | Fails on first run | Use `toHaveScreenshot` with `--update-snapshots` for initial baseline |
| Over-mocking network requests | Not testing the real system | Mock sparingly — only for flaky external dependencies |
| Testing implementation details | Breaks on refactor | Test user-visible behaviour, not internal state |

## TDD Integration

E2E tests follow the same RED-GREEN-REFACTOR cycle:

1. **RED:** Write the failing E2E test first — verify it fails because the feature doesn't exist
2. **GREEN:** Implement the feature
3. **REFACTOR:** Keep tests green

The TDD skill's Iron Law applies: no feature code without a failing test first.

## Quick Reference

| Pattern | Example |
|---|---|
| Navigate | `await page.goto('/dashboard')` |
| Click button | `await page.getByRole('button', { name: 'Save' }).click()` |
| Fill input | `await page.getByLabel('Email').fill('test@example.com')` |
| Select dropdown | `await page.getByLabel('Country').selectOption('AU')` |
| Assert visible | `await expect(page.getByText('Success')).toBeVisible()` |
| Assert URL | `await expect(page).toHaveURL(/\/dashboard/)` |
| Assert title | `await expect(page).toHaveTitle(/Dashboard/)` |
| Wait for API | `await page.waitForResponse(resp => resp.url().includes('/api/save'))` |
| Screenshot | `await expect(page).toHaveScreenshot('dashboard.png')` |
| Network intercept | `await page.route('**/api/slow', route => route.fulfill({ body: '{}' }))` |

## File Structure

```
e2e/
├── tests/
│   ├── auth.spec.ts
│   ├── dashboard.spec.ts
│   └── settings.spec.ts
├── pages/
│   ├── login.page.ts
│   ├── dashboard.page.ts
│   └── settings.page.ts
├── fixtures/
│   └── test-data.ts
└── playwright.config.ts
```

## Key Commands

| Command | Purpose |
|---|---|
| `npx playwright test` | Run all tests |
| `npx playwright test --ui` | Interactive UI mode |
| `npx playwright test path/to/test.spec.ts` | Run specific test |
| `npx playwright codegen URL` | Record interactions |
| `npx playwright show-report` | View HTML report |
| `npx playwright test --update-snapshots` | Update screenshot baselines |

**Output management:** Playwright test runs produce verbose output. Use `npx playwright test 2>&1 | tail -20` for pass/fail checks. For full test suites, use `run_in_background: true` and read the summary. Only request full output when debugging specific failures.

## Integration

**Used by:** `playwright-test-developer` agent
**Referenced from:** `/explore` skill (E2E task generation when `TEST_E2E_CMD` is configured)
**Related:** `test-driven-development` skill (TDD cycle), `systematic-debugging/condition-based-waiting.md` (waiting patterns)
