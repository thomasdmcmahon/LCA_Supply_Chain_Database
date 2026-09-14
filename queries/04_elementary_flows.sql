/*
Elementary flows are the exchanges that cross between the industrial system and nature; resources are taken out (water, ore) and emissions released (CO2, ammonia). They are dead ends in the graph (nothing upstream produces them) and they are what impact scores are computed from.

Scoped to seed data. Add a process filter before running against ELCD.

Run with:
    docker compose exec -T postgres psql -U lca_user -d lca_supply_chain < queries/04_elementary_flows.sql
*/

/*
Every boundary crossing, inputs and outputs. 8 rows on seed data.
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
    LEFT JOIN units u ON u.id = e.unit_id
WHERE f.flow_type = 'elementary'
  AND p.source_dataset = 'Seed data (illustrative)'
ORDER BY e.direction, p.id, e.amount DESC;

/*
Emissions only (the ouputs). There are the rows the LCIA engine joins against characterization_factors
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
    LEFT JOIN units u ON u.id = e.unit_id
WHERE f.flow_type = 'elementary'
  AND e.direction = 'output'
  AND p.source_dataset = 'Seed data (illustrative)'
ORDER BY p.id, e.amount DESC;

/*
Total emitted per flow across processes, to see which substances dominate.

Grouped by f.id, not f.name: ELCD ships several separate rows sharing a name (five for fossil CO2 alone), and grouping by name would add different flows together. Unit is carried along rather than converted.
*/
SELECT
    f.id AS flow_id,
    f.name AS elementary_flow,
    u.name AS unit,
    SUM(e.amount) AS total_amount,
    COUNT(DISTINCT e.process_id) AS process_count
FROM exchanges e
    JOIN processes p ON p.id = e.process_id
    JOIN flows f ON f.id = e.flow_id
    LEFT JOIN units u ON u.id = e.unit_id
WHERE f.flow_type = 'elementary'
  AND e.direction = 'output'
  AND p.source_dataset = 'Seed data (illustrative)'
GROUP BY f.id, f.name, u.name
ORDER BY total_amount DESC;