/*
- LCA Supply Chain Database
- File: 07_elcd_validation.sql
- Description: Post-load validation checks for the ELCD 3.2 pipeline. Confirms that the ELCD subset was loaded, that each ELCD process has one reference flow, and that the main joins behave as expected.

Run with:
    docker compose exec -T postgres psql -U lca_user -d lca_supply_chain < queries/07_elcd_validation.sql
*/

/*
ELCD ROW COUNTS
Checks the size of the ELCD-loaded subset without mixing it up with the seed data.
Expected:
- processes = 7
- flows = 47995
- exchanges = 2278
*/
SELECT 'processes' AS table_name, COUNT(*) AS row_count
FROM processes
WHERE source_dataset = 'ELCD 3.2 via openLCA ILCD export'

UNION ALL

SELECT 'flows' AS table_name, COUNT(*) AS row_count
FROM flows
WHERE external_id IS NOT NULL

UNION ALL

SELECT 'exchanges' AS table_name, COUNT(*) AS row_count
FROM exchanges e
JOIN processes p ON p.id = e.process_id
WHERE p.source_dataset = 'ELCD 3.2 via openLCA ILCD export';

/*
REFERENCE FLOW COUNT PER ELCD PROCESS
Every loaded ELCD process should have exactly one reference flow.
Expected: 7 rows, all with reference_flow_count = 1
*/
SELECT
    p.name AS process,
    COUNT(*) AS reference_flow_count
FROM exchanges e
JOIN processes p ON p.id = e.process_id
WHERE p.source_dataset = 'ELCD 3.2 via openLCA ILCD export'
  AND e.is_reference_flow = TRUE
GROUP BY p.name
ORDER BY p.name;

/*
ELCD PROCESSES WITH NO REFERENCE FLOW
Should return no rows on a clean load.
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
ELCD SAMPLE PROCESS / EXCHANGE / FLOW / UNIT JOIN
Quick sanity check that the relational model works on the loaded ELCD subset.
Expected: joined rows with process name, flow, direction, amount, and unit.
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
ELCD GEOGRAPHY DISTRIBUTION
Shows where the currently loaded ELCD process subset is located.
Expected: a small set of geography codes such as GLO, RER, LU, etc.
*/
SELECT
    g.code,
    g.name,
    COUNT(*) AS process_count
FROM processes p
LEFT JOIN geographies g ON g.id = p.geography_id
WHERE p.source_dataset = 'ELCD 3.2 via openLCA ILCD export'
GROUP BY g.code, g.name
ORDER BY process_count DESC, g.code;
