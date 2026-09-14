/*
Recursive traversal of the product flow graph. Walks upstream from a process by matching each product input to the process that declares the same flow as its reference output. Elementary flows are leaves (nothing produces them), so the recursion does not follow them.

This is the hand-written version, kept because it shows the pattern in one readable query. The parameterized version with automatic scaling lives in schema/07_supply_chain_rollup.sql (use this for real work).

Seed data is two levels deep:
    Flour milling
        <- wheat grain      <- wheat farming
        <- transport, lorry <- Lorry transport

Run with:
    docker compose exec -T postgres psql -U lca_user -d lca_supply_chain < queries/06_supply_chain_graph.sql
*/

/*
Traversal from flour milling (id 3). 3 rows: the start at depth 0, its two suppliers at depth 1.

The cycle guard compares process ids, not names. Names are not unique (ELCD ships 24 separate national electricity processes under one name), so guarding on names would cut a traversal short. path carries names alongside for readability.
*/
WITH RECURSIVE supply_chain AS (

    SELECT
        p.id AS process_id,
        p.name AS process_name,
        NULL::VARCHAR AS supplied_via_flow,
        NULL::NUMERIC AS input_amount,
        NULL::VARCHAR AS input_unit,
        0 AS depth,
        ARRAY[p.id] AS visited,
        ARRAY[p.name]::VARCHAR[] AS path
    FROM processes p
    WHERE p.id = 3

    UNION ALL

    SELECT
        upstream.id,
        upstream.name,
        f.name,
        e_input.amount,
        u.name,
        sc.depth + 1,
        sc.visited || upstream.id,
        sc.path || upstream.name
    FROM supply_chain sc

    JOIN exchanges e_input
        ON e_input.process_id = sc.process_id
        AND e_input.direction = 'input'

    -- Product flows only: these connect to another process. Elementary
    -- flows leave the system and have no producer to walk back to.
    JOIN flows f
        ON f.id = e_input.flow_id
        AND f.flow_type = 'product'

    -- The join that makes it a graph: the upstream process is whichever one
    -- declares this flow as its reference output.
    JOIN exchanges e_ref
        ON e_ref.flow_id = f.id
        AND e_ref.direction = 'output'
        AND e_ref.is_reference_flow = TRUE

    JOIN processes upstream
        ON upstream.id = e_ref.process_id

    LEFT JOIN units u
        ON u.id = e_input.unit_id

    WHERE NOT (upstream.id = ANY(sc.visited))
)

SELECT
    depth,
    REPEAT(' ', depth) || process_name AS process,
    supplied_via_flow,
    input_amount,
    input_unit
FROM supply_chain
ORDER BY depth, process_name;


/*
Cradle-to-gate inventory for 1 kg of flour: every upstream process's emissions, scaled by how much of that process is needed, summer per substance.

The scaling factors are typed by hand here. 1.35 kg grain and 0.27 tkm transport per kg flour, read straight off the milling process's inputs. That is the whole point of this file: showing the arithmetic before it was generalized. supply_chain_scaled_processes() dervies the same numbers from the schema instead.
*/
SELECT
    f.id AS flow_id,
    f.name AS elementary_flow,
    u.name AS unit,
    ROUND(SUM(e_emission.amount * scale.factor), 10) AS scaled_total_amount
FROM (
    VALUES
        (3, 1.00),  -- flour milling: the functional unit itself
        (1, 1.35),  -- wheat farming: 1.35 kg grain per kg flour
        (2, 0.27)   -- lorry transport: 0.27 tkm per kg flour
) AS scale (process_id, factor)

JOIN exchanges e_emission
    ON e_emission.process_id = scale.process_id
    AND e_emission.direction = 'output'

JOIN flows f
    ON f.id = e_emission.flow_id
    AND f.flow_type = 'elementary'

LEFT JOIN units u
    ON u.id = e_emission.unit_id

GROUP BY f.id, f.name, u.name
ORDER BY scaled_total_amount DESC;