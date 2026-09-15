/*
The supply chain rollup: walk upstream from a process, work out how much of each upstream
process is needed, and add up what the whole chain emits.

This generalizes the hand-written example in queries/06_supply_chain_graph.sql,
where the scaling factors were typed in by hand for one specific chain.

Run after 01, 02, 03 and 05 (needs convert_amount())

TRAVERSAL
A process's product input is matched to the upstream process that declares
the same flow as its reference output. Elementary flows are leaves, nothing produces them,
so they are not followed.

The schema does not enfore one producer per flow, so if several processes declare the
same reference output, the join fans out to all of them. That is not hypothetical:
ELCD models European Electricity as 24 separate national processes sharing one flow,
so a single electricity input resolves to all 24 branches. Expected behavior, and this file
does not try to pick one.

SCALING
Every exchagne amount is already "per one unit of that process's own reference flow".
So the multiplier for an upstream process is just the amount needed divided by the
amount it produces, compoudning down the chain:

    scale(start)    = target_amount / start.reference_amount
    scale(upstream) = scale(consumer)
                        * input (amount_in_upstream_ref_unit
                        / upstream.reference_amount)

convert_amount() reconciles the input into the upstream's reference unit first.
If they cannot convert, that branch's cumulative_scale goes NULL and stays NULL
for everything below it (traversal continues so the broken branch stays visible,
but nothing under it reaches the inventory.)

Hand-verified against the seed data (1 kg of flour from process 3):
milling = 1, wheat farming = 1.35, lorry transport = 0.27, matching the manual
VALUES list in queries/06 exactly. queries/10 has the full comparison.

Untested: the seed data is a tree, so the guard has never actually fired.
*/

/*
One row per process reachable upstream, including the start at depth 0, with
the factor needed to express its exchanges in terms of target_amount units of the
start process's reference flow.

Returns nothing if the start process has no reference flow (there is no functional
unit to scale against).
*/
CREATE OR REPLACE FUNCTION supply_chain_scaled_processes(
    p_start_process_id INT,
    p_target_amount NUMERIC,
    p_max_depth INT DEFAULT 50
) RETURNS TABLE (
    process_id INT,
    process_name VARCHAR,
    depth INT,
    path INT[],
    cumulative_scale NUMERIC
)
LANGUAGE sql
STABLE
AS $$
    WITH RECURSIVE chain AS (

        -- Anchor: the starting process, scaled against its own reference flow.
        SELECT
            p.id AS process_id,
            p.name AS process_name,
            0 AS depth,
            ARRAY[p.id] AS path,
            p_target_amount / NULLIF(ref.amount, 0) AS cumulative_scale
        FROM processes p
        JOIN exchanges ref
            ON ref.process_id = p.id
            AND ref.is_reference_flow = TRUE
        WHERE p.id = p_start_process_id

        UNION ALL

        -- Recursive step: for each product input of the current process,
        -- find the upstream process whose reference output is that flow.
        SELECT
            upstream.id AS process_id,
            upstream.name AS process_name,
            chain.depth + 1 AS depth,
            chain.path || upstream.id AS path,
            chain.cumulative_scale * (
                convert_amount(e_input.amount, e_input.unit_id, e_ref.unit_id)
                / NULLIF(e_ref.amount, 0)
            ) AS cumulative_scale
        FROM chain

        JOIN exchanges e_input
            ON e_input.process_id = chain.process_id
            AND e_input.direction = 'input'

        JOIN flows f
            ON f.id = e_input.flow_id
            AND f.flow_type = 'product'

        JOIN exchanges e_ref
            ON e_ref.flow_id = f.id
            AND e_ref.direction = 'output'
            AND e_ref.is_reference_flow = TRUE

        JOIN processes upstream
            ON upstream.id = e_ref.process_id

        WHERE NOT (upstream.id = ANY(chain.path))
          AND chain.depth < p_max_depth
    )
    SELECT process_id, process_name, depth, path, cumulative_scale
    FROM chain;
$$;

COMMENT ON FUNCTION supply_chain_scaled_processes(INT, NUMERIC, INT) IS
    'Recursive upstream traversal from a process, with automatically computed cumulative scaling factors relative to target_amount units of the process''s reference flow. Cycle-safe (visited-id guard + depth cap). See file header for the scaling formula.';


/*
The cradle-to-gate inventory: every elementary exchange in the scaled chain,
aggregated into one row per flow.

Each contribution is converted into the flow's own default unit before summing,
so the same substance recorded in different units at different processes still
lands in one row rather than splitting into several.

skipped_unconvertible_count is how many contributions to that flow could not be
converted and were left out of total_amount. Usually 0 (most exchanges already
use their flow's default unit).
*/
CREATE OR REPLACE FUNCTION supply_chain_inventory(
    p_start_process_id INT,
    p_target_amount NUMERIC,
    p_max_depth INT DEFAULT 50
) RETURNS TABLE (
    flow_id INT,
    flow_name VARCHAR,
    unit_id INT,
    unit_name VARCHAR,
    total_amount NUMERIC,
    skipped_unconvertible_count INT
)
LANGUAGE sql
STABLE
AS $$
    WITH contributions AS (
        SELECT
            f.id AS flow_id,
            f.name AS flow_name,
            f.unit_id AS unit_id,
            convert_amount(e.amount, e.unit_id, f.unit_id) * chain.cumulative_scale AS scaled_amount
        FROM supply_chain_scaled_processes(p_start_process_id, p_target_amount, p_max_depth) AS chain
        JOIN exchanges e
            ON e.process_id = chain.process_id
        JOIN flows f
            ON f.id = e.flow_id
            AND f.flow_type = 'elementary'
        WHERE chain.cumulative_scale IS NOT NULL
    )
    SELECT
        contributions.flow_id,
        contributions.flow_name,
        contributions.unit_id,
        u.name AS unit_name,
        SUM(contributions.scaled_amount) FILTER (WHERE contributions.scaled_amount IS NOT NULL),
        COUNT(*) FILTER (WHERE contributions.scaled_amount IS NULL)::INT
    FROM contributions
    LEFT JOIN units u ON u.id = contributions.unit_id
    GROUP BY contributions.flow_id, contributions.flow_name, contributions.unit_id, u.name;
$$;

COMMENT ON FUNCTION supply_chain_inventory(INT, NUMERIC, INT) IS
    'Cradle-to-gate elementary inventory: aggregates supply_chain_scaled_processes() elementary exchanges into one row per flow, normalized to the flow''s default unit. Feeds directly into calculate_cradle_to_gate_impacts() below.';


/*
The inventory above, characterized the same way calculate_direct_impacts() handles
a single process.

Read-only on purpose. A cradle-to-gate result depends on the target amount
and depth it was computed with, and impact_results is keyed only on process
and category (storing it there would lose the scope that makes the number mean anything).
*/
CREATE OR REPLACE FUNCTION calculate_cradle_to_gate_impacts(
    p_start_process_id INT,
    p_target_amount NUMERIC,
    p_max_depth INT DEFAULT 50
) RETURNS TABLE (
    impact_category_id INT,
    value NUMERIC,
    characterized_flow_count INT,
    skipped_flow_count INT
)
LANGUAGE sql
STABLE
AS $$
    WITH contributions AS (
        SELECT
            cf.impact_category_id AS impact_category_id,
            convert_amount(inv.total_amount, inv.unit_id, cf.unit_id) AS amount_in_cf_unit,
            cf.factor AS factor
        FROM supply_chain_inventory(p_start_process_id, p_target_amount, p_max_depth) AS inv
        JOIN characterization_factors cf
            ON cf.flow_id = inv.flow_id
        WHERE inv.total_amount IS NOT NULL
    )
    SELECT
        contributions.impact_category_id,
        SUM(contributions.amount_in_cf_unit * contributions.factor)
            FILTER (WHERE contributions.amount_in_cf_unit IS NOT NULL),
        COUNT(*) FILTER (WHERE contributions.amount_in_cf_unit IS NOT NULL)::INT,
        COUNT(*) FILTER (WHERE contributions.amount_in_cf_unit IS NULL)::INT
    FROM contributions
    GROUP BY contributions.impact_category_id;
$$;

COMMENT ON FUNCTION calculate_cradle_to_gate_impacts(INT, NUMERIC, INT) IS
    'Cradle-to-gate LCIA impacts: supply_chain_inventory() characterized the same way calculate_direct_impacts() characterizes a single process''s direct exchanges. Read-only (no impact_results row implies "cradle-to-gate" scope, which the process/category-keyed impact_results table cannot represent without also storing the target_amount and max_depth used -- left as a query-time result rather than persisted).';
