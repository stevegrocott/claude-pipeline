# Technology-Specific Review Checklist

Apply these checks when reviewing code changes. Only check items relevant to the files modified.

## TypeScript
- No implicit `any` types
- Proper use of discriminated unions and type guards
- Exhaustive switch/case handling with `never` checks
- Correct `async/await` usage (no floating promises)
- Proper error boundaries in React components

## Fastify Backend
- Response schemas declared for all routes (fast-json-stringify strips undeclared fields)
- Proper Prisma transaction usage for multi-step operations
- Authentication middleware applied to protected routes
- Input validation via Fastify JSON Schema

## Next.js Frontend
- Server components vs client components used appropriately
- Proper use of `useSearchParams()` with `<Suspense>` boundaries
- Data fetching follows established patterns (API proxy routes)
- Accessible markup with proper ARIA attributes

## Testing
- Jest unit tests for services and utilities
- Playwright E2E tests for user-facing flows
- Test data cleanup to avoid accumulation across runs
- No subprocess calls in unit tests (use direct APIs)
