/*
- LCA Supply Chain Database
- File: 04_elementary_flows.sql
- Description: Filters exchanges to elementary flows only –– the substances that cross the boundary between the industrial systems and nature.
These are the environmentally significant flows that drive LCIA scores

Inputs: resources drawn from nature (e.g. water abstraction).
Outputs: emissions released to nature (e.g. CO2, ammonia, nitrate)

Run with:
    docker compose exec -T postgres psql -U lca_user -d lca_supply_chain < queries/04_elementary_flows.sql
*/

/*
ALL ELEMENTARY FLOWS ACROSS ALL PROCESSES
Full picture of system boundary crossings, both resource inputs and emissions to air, water, and soil.
-- Expected: 8 rows (1 input: water; 7 outputs: CO2 x3, ammonia, nitrate, phosphate, NOx)
*/
SELECT
    p.name AS process,
    e.direction,
    f.name AS elementary_flow,
    f.cas_number,
    e.amount,
    u.name AS unit
FROM exchanges e
    JOIN processes p ON p.id = e.process_id
    JOIN flows f ON f.id = e.flow_id
    JOIN units u ON u.id = e.unit_id
WHERE f.flow_type = 'elementary'
ORDER BY e.direction, p.id, e.amount DESC;

/*
EMISSIONS TO NATURE (OUTPUTS ONLY)
The subset that contributes to environmental impact scores.
-- Expected: 7 rows
*/
SELECT
    p.name AS process,
    f.name AS emission,
    f.cas_number,
    e.amount,
    u.name AS unit
FROM exchanges e
    JOIN processes p ON p.id = e.process_id
    JOIN flows f ON f.id = e.flow_id
    JOIN units u ON u.id = e.unit_id
WHERE f.flow_type = 'elementary'
    AND e.direction = 'output'
ORDER BY p.id, e.amount DESC;

/*
EMISSIONS AGGREGATED BY FLOW ACROSS ALL PROCESSES
- Shows the total inventory for each elementaty flow summer over all processes. Useful for identifying which substances dominate the overall inventory.
-- Expected: 5 rows (CO2, ammonia, nitrate, phosphate, NOx, water)
*/
SELECT
    f.name AS elementary_flow,
    u.name AS unit,
    SUM(e.amount) AS total_amount,
    COUNT(DISTINCT e.process_id) AS process_count
FROM exchanges e
    JOIN flows f ON f.id = e.flow_id
    JOIN units u ON u.id = e.unit_id
WHERE f.flow_type = 'elementary'
    AND e.direction = 'output'
GROUP BY f.name, u.name
ORDER BY total_amount DESC;