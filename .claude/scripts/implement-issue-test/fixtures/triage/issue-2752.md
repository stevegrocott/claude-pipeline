# Add `hasBaseline` filter param to `GET /api/farms` backend

The dashboard wants to filter the farm list by whether a baseline assessment
has been completed. We need a new query parameter on the farms endpoint and
the corresponding service-layer support.

## Implementation Tasks

- **(M)** In `apps/api/src/routes/farms.ts`, add a `hasBaseline` query
  parameter (boolean, optional) to the `GET /api/farms` route. Validate via
  the Zod schema for the route. When provided, pass it to the farms service.

- **(M)** In `apps/api/src/services/farms.service.ts`, extend the
  `listFarms()` method to accept an optional `hasBaseline` filter and
  translate it to a Prisma `where` clause:
  - `true` → farms with at least one record in `baseline_assessments`
  - `false` → farms with no record
  - undefined → no filter

- **(M)** In `apps/api/test/integration/farms.spec.ts`, add integration tests
  covering all three states. Use the existing `farmFactory` fixtures.

- **(S)** In `packages/api-client/src/farms.ts`, regenerate the typed client
  to include the new param.

## Affected files
- `apps/api/src/routes/farms.ts`
- `apps/api/src/services/farms.service.ts`
- `apps/api/test/integration/farms.spec.ts`
- `packages/api-client/src/farms.ts`

## Acceptance criteria

- `GET /api/farms?hasBaseline=true` returns only farms with baselines
- `GET /api/farms?hasBaseline=false` returns only farms without
- Integration tests pass
- Typed client exposes the new parameter
