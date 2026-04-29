/*
- LCA Supply Chain Database
- File: 02_exchanges_by_process.sql
- Description: Human-readable bill of materials for each process.
    Joins exchanges to processes, flows, and units.
    This is the core join pattern that most outer queries build on.

Run with:
    docker compose exec -T postgres psql -U lca_user -d lca_supply_chain < queries/02_exchanges_by_process.sql
*/

/* ALL EXHCANGES WITH CONTEXT
Shows every exchange across all processes, with flow name, direction, 
amount, unit, and whether it is the reference flow.
-- Expected: 17 rows
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
    JOIN units u ON u.id = e.unit_id
ORDER BY p.id, e.direction DESC, e.is_reference_flow DESC;

/*
INPUTS PER PROCESS
What each process consumes, excluding the reference flow.
Useful for reading the supply chain left ro right.
-- Expected: 3 rows for wheat farming, 1 for transport, 3 for flour milling
*/
SELECT
    p.name AS process,
    f.name AS input_flow,
    f.flow_type,
    e.amount,
    u.name AS unit
FROM exchanges e
    JOIN processes p ON p.id = e.process_id
    JOIN flows f ON f.id = e.flow_id
    JOIN units u ON u.id = e.unit_id
WHERE e.direction = 'input'
ORDER BY p.id, f.flow_type;

/*
OUTPUTS PER PROCESS
What each process produces or emits.
-- Expected: 5 rows for wheat farming, 3 for transport, 2 for flour milling
*/
SELECT
    p.name AS process,
    f.name AS output_flow,
    f.flow_type,
    e.amount,
    u.name AS unit,
    e.is_reference_flow
FROM exchanges e
    JOIN processes p ON p.id = e.process_id
    JOIN flows f ON f.id = e.flow_id
    JOIN units u ON u.id = e.unit_id
WHERE e.direction = 'output'
ORDER BY p.id, e.is_reference_flow DESC, f.flow_type;