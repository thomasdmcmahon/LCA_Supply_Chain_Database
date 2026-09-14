/*
Post-load validation for the ELCD 3.2 pipeline. Run after make pipeline.

Everything here is scoped to source_dataset so the checks say something about the load specifically, not about the seed data mixed in with it.

Run with:
    docker compose exec -T postgres psql -U lca_user -d lca_supply_chain < queries/07_elcd_validation.sql
    make validate
*/

/*
Row counts for the loaded subset.
Expected: processes 608, exchanges 212153.

Flows are counted by external_id rather than source_dataset, because flows have no source_dataset column, they are shared lookups and a flow loaded from ELCD is identified by carrying a source UUID. Seed flows have none.
*/
SELECT 'processes' AS table_name, COUNT(*) AS row_count
FROM processes
WHERE source_dataset = 'ELCD 3.2 via openLCA ILCD export'

UNION ALL

SELECT 'flows', COUNT(*)
FROM flows
WHERE external_id IS NOT NULL

UNION ALL

SELECT 'exchanges', COUNT(*)
FROM exchanges e
JOIN processes p ON p.id = e.process_id
WHERE p.source_dataset = 'ELCD 3.2 via openLCA ILCD export';

/*
Reference flows per process, summarised. The per-process count can only ever be 1 (the partial unique undex makes two unstorable), so what this actually checks is that the distribution holds no surprises, in one row instead of 608.
*/
SELECT
    COUNT(*) AS processes_with_reference_flow,
    MIN(cnt) AS min_per_process,
    MAX(cnt) AS max_per_process
FROM (
    SELECT p.id, COUNT(*) AS cnt
    FROM exchanges e
    JOIN processes p ON p.id = e.process_id
    WHERE p.source_dataset = 'ELCD 3.2 via openLCA ILCD export'
      AND e.is_reference_flow = TRUE
    GROUP BY p.id
) per_process;

/*
The real check: processes the loader without a reference flow. Nothing in the database enforces "at least one", so this is where a bad load shows. A process listed here cannot be scaled, and the supply chain traversal returns zero rows for it.

Expected: 0 rows
*/
SELECT
    p.id,
    p.name
FROM processes p
WHERE p.source_dataset = 'ELCD 3.2 via openLCA ILCD export'
  AND NOT EXISTS (
      SELECT 1
      FROM exchanges e
      WHERE e.process_id = p.id
        AND e.is_reference_flow = TRUE
  )
ORDER BY p.id;

/*
A sample of the full join, to confirm the relational model holds against real data rather than just three hand-written processes.
*/
SELECT
    p.name AS process,
    e.direction,
    f.name AS flow,
    e.amount,
    u.name AS unit,
    e.is_reference_flow
FROM exchanges e
JOIN processes p ON p.id = e.process_id
JOIN flows f ON f.id = e.flow_id
LEFT JOIN units u ON u.id = e.unit_id
WHERE p.source_dataset = 'ELCD 3.2 via openLCA ILCD export'
ORDER BY p.name, e.is_reference_flow DESC, e.direction, f.name
LIMIT 50;

/*
Geography spread. A NULL row here menas processes the transform could not map to a geography. Worth knowing since geography is how the 24 national electricity mixes are told apart.
*/
SELECT
    g.code,
    g.name,
    COUNT(*) AS process_count
FROM processes p
LEFT JOIN geographies g ON g.id = p.geography_id
WHERE p.source_dataset = 'ELCD 3.2 via openLCA ILCD export'
GROUP BY g.code, g.name
ORDER BY process_count DESC, g.code;ß