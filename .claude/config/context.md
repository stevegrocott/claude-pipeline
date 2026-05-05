# Project Context

This file is injected into agent prompts by the orchestrator to give agents
consistent knowledge of the project's patterns, conventions, and architecture.

Project teams should document here:
- Coding conventions and style rules specific to this codebase
- Architectural patterns agents should follow or avoid
- Key domain concepts and terminology
- Important file/directory conventions
- Any project-specific constraints (e.g., banned libraries, required patterns)

The orchestrator reads this file via `PLATFORM_CONTEXT_FILE` (configured in
`platform.sh`) and passes its contents to agents as supplemental context.
Leave this file empty or remove entries that no longer apply.

Keep this file short (10–20 rules max). Every line costs tokens on every stage.
Delete entries when they're no longer relevant.

---

## Anti-Patterns

<!-- List patterns that look correct but break at runtime in this project.
     One line per rule. Be specific: name the bad pattern, then the fix. -->

<!-- Examples (delete and replace with your own):
- NEVER use `waitForLoadState('networkidle')` — SSE connections keep the network active indefinitely; use `waitForLoadState('domcontentloaded')` or `waitForSelector` instead
- NEVER call `$queryRaw` without a surrounding `try/catch` — unhandled Prisma raw errors return a 500 instead of a graceful null response
- NEVER import from `@/lib/db` directly in API routes — use the service layer in `src/services/` to keep transaction boundaries consistent
-->

## Table Names and Query Patterns

<!-- Document the canonical table/collection names and query conventions for
     this project. Raw SQL strings are opaque to TypeScript type-checking, so
     agents must have the correct names here. -->

<!-- Examples (delete and replace with your own):
- Correct table name: `climate_grid_cells` (NOT `climate_pool_grid_cells`)
- Correct table name: `silo_cells` — the join key is `cell_id` (NOT `silo_id`)
- Spatial lookups: always use `ST_Within(point, polygon)` — do NOT use `ST_Intersects` for point-in-polygon checks (false positives at boundaries)
- Climate data queries: always JOIN through `climate_grid_cells` → `climate_data` — do NOT query `climate_data` directly without the grid cell filter
-->

## Test Patterns

<!-- Document testing conventions, especially for async, SSE, or flaky-prone
     scenarios where the obvious approach is wrong. -->

<!-- Examples (delete and replace with your own):
- Use `page.waitForSelector('[data-testid="result"]')` to detect data load — do NOT use `waitForLoadState('networkidle')` (SSE keeps the connection open)
- Seed test data via `prisma.$executeRaw` fixtures, not API calls — API calls add latency and couple tests to unrelated endpoints
- Playwright: always call `page.goto(BASE_URL)` with `waitUntil: 'domcontentloaded'` option to avoid hanging on long-poll routes
- Mock external HTTP calls with `msw` — do NOT let tests hit real third-party APIs; mark any test that does as `@skip` until mocked
-->

## Existing Service Patterns

<!-- When adding a new feature that touches a shared service or shared table,
     point agents to the canonical existing implementation to follow. -->

<!-- Examples (delete and replace with your own):
- Climate lookups: see `src/services/climate-service.ts` → `getClimateForLocation()` — copy this pattern, do NOT write a new raw query
- Irrigation suitability: see `src/services/irrigation-service.ts` for the canonical cell lookup pattern
- Auth middleware: always use `withAuth()` HOC from `src/middleware/auth.ts` — do NOT replicate the JWT decode logic inline
-->

## Environment Notes

<!-- Document environment-specific facts that aren't obvious from the code:
     connection limits, background job constraints, feature flags, etc. -->

<!-- Examples (delete and replace with your own):
- Database: connection pool limit is 10 in staging; keep queries short and avoid N+1 patterns
- Background jobs: the job runner (`src/jobs/`) is single-threaded — avoid `Promise.all` with more than 5 concurrent DB calls
- Feature flags: `ENABLE_SSE=true` must be set for real-time irrigation updates; without it the polling fallback is used
-->
