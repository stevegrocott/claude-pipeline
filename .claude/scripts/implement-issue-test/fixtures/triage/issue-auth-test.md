# Update auth-flow E2E test for new MFA prompt

The login flow now shows an MFA prompt after password entry for accounts
with MFA enabled. The auth-flow E2E test needs a single-line update to wait
for and dismiss the prompt for the test user (which has MFA disabled, so
the prompt actually shouldn't appear — the test should assert it doesn't).

## Implementation Tasks

- **(S)** In `playwright/auth-flow.spec.ts`, line 42, after `await
  page.fill('#password', testPassword)` and `await page.click('#submit')`,
  add `await expect(page.locator('#mfa-prompt')).not.toBeVisible({
  timeout: 2000 })` to assert the MFA prompt does NOT appear for the
  non-MFA test user.

## Affected files
- `playwright/auth-flow.spec.ts`

## Acceptance criteria

- Test passes with non-MFA test account
- Test fails (correctly) if MFA prompt appears unexpectedly
