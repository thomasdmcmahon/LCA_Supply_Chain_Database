/*
- LCA Supply Chain Database
- File: 03_reference_flows.sql
- Description: Identifies the reference flow for each process and verifies the one-per-process constrant holds. The reference flow defines the functional unit of a process -- all other exchange amounts are relative to it.

Run with:
      docker compose exec -T postgres psql -U lca_user -d lca_supply_chain < queries/03_reference_flows.sql
*/

/*
REFERENCE FLOW PER PROCESS
Shows the functional unit for each process: what it produces and in what quantity. This is the denominator for every other exchange amount.
-- Expected: 3 rows, one per process.
*/
SELECT
    p.name AS process,
    f.name AS reference_flow,
    e.amount,
    u.name AS unit,
    g.code AS geography
FROM exchanges e
    JOIN processes p ON p.id = e.process_id
    JOIN flows f ON f.id = e.flow_id
    JOIN units u ON u.id = e.unit_id
    LEFT JOIN geographies g ON g.id = p.geography_id
WHERE e.is_reference_flow = TRUE
ORDER BY p.id;

/*
REFERENCE FLOW COUNT PER PROCESS
Verifies the constraint: every process must have exactly one reference flow. Any row showing a count other than 1 indicates a data integrity problem.
-- Expected: 3 rows, all with reference_flow_count = 1
*/
SELECT
    p.id AS process_id,
    p.name AS process,
    COUNT(*) AS reference_flow_count
FROM exchanges e
    JOIN processes p ON p.id = e.process_id
WHERE e.is_reference_flow = TRUE
GROUP BY p.id, p.name
ORDER BY p.id;

/*
PROCESSES WITH NO REFERENCE FLOW
The unique index in 02_constraints.sql enforces at most one reference flow per process, but not at least one. This query surfaces any process that slipped through without.
-- Expcted: 0 (should return 0 rows on clean data)
*/
SELECT
    p.id,
    p.name AS process
FROM processes p
WHERE NOT EXISTS
(
    SELECT 1
FROM exchanges e
WHERE e.process_id = p.id
    AND e.is_reference_flow = TRUE
)
ORDER BY p.id;