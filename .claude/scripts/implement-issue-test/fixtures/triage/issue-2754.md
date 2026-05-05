# Fix zone overlap validator to exclude the zone being updated

The zone overlap validator (`validateNoZoneOverlap` in
`apps/api/src/services/zones/overlap-validator.ts`) currently checks the
incoming zone polygon against ALL existing zones in the same farm. When
updating a zone, this includes the zone being updated against itself — every
update fails with "zone overlaps with zone N" where N is the zone's own ID.

## Implementation Tasks

- **(M)** In `apps/api/src/services/zones/overlap-validator.ts`, modify
  `validateNoZoneOverlap(farmId, polygon, excludeZoneId?)` to accept an
  optional `excludeZoneId` parameter. When provided, skip that zone in the
  overlap check.

- **(M)** In `apps/api/src/services/zones/zones.service.ts`, the
  `updateZone(zoneId, updates)` method must pass `zoneId` as the
  `excludeZoneId` argument when validating polygon updates.

- **(L)** Add unit tests for the validator covering: self-overlap (the bug),
  partial overlap with a sibling zone, exact overlap with a sibling, edge
  case where two zones share a single border vertex (touching but not
  overlapping — should pass), edge case where the polygon is
  self-intersecting (should fail with a different error).

## Affected files
- `apps/api/src/services/zones/overlap-validator.ts`
- `apps/api/src/services/zones/zones.service.ts`
- `apps/api/test/unit/zones/overlap-validator.spec.ts`

## Acceptance criteria

- Updating a zone's polygon no longer fails with "zone overlaps with itself"
- Sibling overlaps still detected
- Touching-but-not-overlapping case correctly distinguished from overlap
- Self-intersecting input rejected with clear error
