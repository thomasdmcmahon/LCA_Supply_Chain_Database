/*
The reference flow is the output that defines what a process makes (1kg of flour, 1000m2 of carton board, ...). Every other amount on that process is per one unit of it, so without it the numbers have no denominator.

Run with:
    docker compose exec -T postgres psql -U lca_user -d lca_supply_chain < queries/03_reference_flows.sql
*/

/*
The functional unit of each process. 3 rows on seed data.
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
Counts per process. This cannot return anything but 1 (the partial unique index in 02_constraints.sql makes two reference flows unstorable), so it demonstrates the constraint rather than testing it. Kept becuase seeing the count is the quickest way to confirm which rule is in force.
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
The real check. The database enforces at most one reference flow per process, but nothing enforces at least one (that is the loaders job). Any row here is a process where exchange amounts have no denominator, and which the supply chain traversal will return zero rows for.

0 rows expected on seed data. Run this after every ELCD load.
*/
SELECT
    p.id,
    p.name AS process,
    p.source_dataset
FROM processes p
WHERE NOT EXISTS
(
    SELECT 1
FROM exchanges e
WHERE e.process_id = p.id
    AND e.is_reference_flow = TRUE
)
ORDER BY p.id;