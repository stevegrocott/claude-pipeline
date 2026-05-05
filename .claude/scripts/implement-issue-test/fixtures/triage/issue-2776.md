# Fix `window.location.href` → `router.push()` for post-login redirect

The post-login redirect in `apps/web/src/components/LoginForm.tsx` uses
`window.location.href = redirectTo` which triggers a full page reload and
loses the in-memory auth state set by the client SDK. Switch to the Next.js
router so the redirect is a client-side navigation.

## Implementation Tasks

- **(S)** In `apps/web/src/components/LoginForm.tsx`, line 87, replace
  `window.location.href = redirectTo` with `router.push(redirectTo)`. Import
  `useRouter` from `next/navigation` at the top of the file.

- **(S)** In `apps/web/src/components/LoginForm.tsx`, validate that
  `redirectTo` is a relative path (starts with `/`) before passing to
  `router.push` to prevent open-redirect attacks. Throw or fall back to `/`
  if it's an absolute URL.

## Affected files
- `apps/web/src/components/LoginForm.tsx`

## Acceptance criteria

- Successful login uses client-side navigation
- Auth state preserved across redirect
- Open-redirect protection: external URLs rejected
