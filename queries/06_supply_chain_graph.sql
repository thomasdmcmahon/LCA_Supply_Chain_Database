/*
- LCA Supply Chain Database
- File: 06_supply_chain_graph.sql
- Description: Recursive CTE that walks the product flow graph upstream from a given process, resolving which process supplies each product input.

    The graph is traversed by matching product flow inputs to the process that declares the same flow as its reference output. Elementary flows (emissions, resources) are not traversed –– they are leaf nodes that cross the system boundary rather than connecting to another process.

    With the seed data the graph is two levels deep:
        Flour milling
            <- Wheat grain      <- Wheat farming
            <- Transport, lorry <- Lorry transport

Run with:
    docker compose exec -T postgres psql -U lca_user -d lca_supply_chain < queries/06_supply_chain_graph.sql
*/

/*
SUPPLY CHAIN GRAPH TRAVERSAL
Starting process: Flour mulling, wheat, RER (id = 3)

How the recursion works:
    Anchor: select the starting process and its reference flow.
    Recursive step: for each product input of the current process,
        find the upstream process whose reference output is that same flow, then recurse into that upstream process.
    Termination: when a process has no further product inputs that resolve to an upstream process, the recursion stops.

depth tracks how many steps upstream we are from the starting process.
path accumulates process names to make the chain readable.

-- Expected: 3 rows (flour milling at depth 0, wheat farming and
            lorry transport at depth 1)
*/
WITH RECURSIVE supply_chain AS (

    -- Anchor: the starting process
    SELECT
        p.id AS process_id,
        p.name AS process_name,
        NULL::VARCHAR AS supplied_via_flow,
        NULL::NUMERIC AS input_amount,
        NULL::VARCHAR AS input_unit,
        0 AS depth,
        ARRAY[p.name]::VARCHAR[] AS path
    FROM processes p
    WHERE p.id = 3 -- Flour milling, wheat, RER

    UNION ALL

    -- Recursive step: find upstream processes that supply product inputs
    SELECT
        upstream.id AS process_id,
        upstream.name AS process_name,
        f.name AS supplied_via_flow,
        e_input.amount AS input_amount,
        u.name AS input_unit,
        sc.depth + 1 AS depth,
        sc.path || upstream.name AS path
    FROM supply_chain sc

    -- Walk to each product input of the current process
    JOIN exchanges e_input
        ON e_input.process_id = sc.process_id
        AND e_input.direction = 'input'

    -- Only follow prodcut flows, not elementary flows
    JOIN flows f
        ON f.id = e_input.flow_id
        AND f.flow_type = 'product'

    -- Find the upstream process whose reference output is this input flow
    JOIN exchanges e_ref
        ON e_ref.flow_id = f.id
        AND e_ref.direction = 'output'
        AND e_ref.is_reference_flow = TRUE
    
    JOIN processes upstream
        ON upstream.id = e_ref.process_id
    
    JOIN units u
        ON u.id = e_input.unit_id
    
    -- Guard against cycles (not present in this dataset)
    WHERE upstream.name <> ALL(sc.path)
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
FULL UPSTREAM INVETORY ROLLUP
Aggregates all elementary flow outputs across the entire upstream supply chain of flour milling, weighted by the input amounts at each stage. This approximates the cradle-to-gate inventory for 1 kg of wheat flour.

Scaling logic:
    - Flour milling inputs 1.35 kg wheat grain per kg flour, so wheat farming emissions are multiplied by 1.35.
    - Flour milling inputs 0.27 tkm transport per kg flour, so lorry transport emissions are multiplied by 0.27.

-- Expected: emissions from all thre processes, scaled and summed by substance.
*/
SELECT
    f.name AS elementary_flow,
    u.name AS unit,
    ROUND(
        SUM(
            e_emission.amount * scale.factor
        ),
        10
    ) AS scaled_total_amount
FROM (
    
    -- Define the scaling factor for each upstream process relative to 1 kg of wheat flour (the functional unit)
    VALUES
        (3, 1.00), -- Flour mulling: 1.00 kg flour
        (1, 1.35), -- What farming: 1.35 kg grain input per kg flour
        (2, 0.27) -- Lorry transport: 0.27 tkm input per kg flour
) AS scale (process_id, factor)

JOIN exchanges e_emission
    ON e_emission.process_id = scale.process_id
    AND e_emission.direction = 'output'

JOIN flows f
    ON f.id = e_emission.flow_id
    AND f.flow_type = 'elementary'

JOIN units u
    ON u.id = e_emission.unit_id

GROUP BY f.name, u.name
ORDER BY scaled_total_amount DESC;