/*
- LCA Supply Chain Database
- File: 07_supply_chain_rollup.sql
- Description: Generic, parameterized cradle-to-gate supply-chain rollup.
  Generalizes the manual example in queries/06_supply_chain_graph.sql into
  callable functions: automatic scaling factors, cycle-safe termination, and
  an aggregated elementary inventory usable directly by the LCIA calculation
  engine (06_lcia_calculation.sql).

Run after 01_create_tables.sql, 02_constraints.sql, 03_seed_data.sql, and
05_unit_conversions.sql (needs convert_amount()).

GRAPH TRAVERSAL PATTERN
Unchanged from queries/06_supply_chain_graph.sql: a process's product INPUT
flow is matched to the upstream process that declares the same flow as its
is_reference_flow OUTPUT. Elementary flows are leaves, not traversed. If more
than one process declares the same flow as its reference output, the join
fans out to all of them (the schema doesn't enforce a single producer per
flow) -- that's existing, expected behavior, not something this file
resolves.

SCALING
Every exchange amount is "per one unit of the process's own reference flow"
(see exchanges.amount comment in 01_create_tables.sql). So the amount needed
from an upstream process, expressed in the upstream's own reference-flow
unit, divided by the upstream's reference-flow amount, is exactly the
multiplier to scale that upstream process's whole exchange list by. This
compounds multiplicatively down the chain:

    scale(start)    = target_amount / start.reference_amount
    scale(upstream)  = scale(consumer) * (input_amount_in_upstream_ref_unit / upstream.reference_amount)

convert_amount() reconciles input_amount into the upstream's reference-flow
unit first, in case they're recorded in different-but-compatible units. If
they're not convertible, that branch's cumulative_scale becomes NULL and
stays NULL for everything beneath it (traversal continues -- so the broken
branch is still visible for debugging -- but nothing under it contributes to
the aggregated inventory).

Hand-verified against the seed wheat-flour example (target: 1 kg flour from
process id 3): scale(flour milling)=1, scale(wheat farming)=1.35,
scale(lorry transport)=0.27 -- matching queries/06_supply_chain_graph.sql's
manual VALUES list exactly. See queries/10_supply_chain_rollup_examples.sql
for the full worked comparison.

CYCLE SAFETY
`path` accumulates visited process ids (not names, unlike the manual
example -- ids are the correct guard since process names are not
guaranteed unique). An upstream process already in `path` is not
re-entered. `p_max_depth` (default 50) additionally caps recursion depth as
a hard backstop.
*/

/*
--- supply_chain_scaled_processes(start_process_id, target_amount, max_depth) ---
The traversal itself. One row per process reachable upstream of the start
process (including the start process, at depth 0), with the cumulative
scaling factor needed to express that process's exchanges in terms of
target_amount units of the start process's reference flow.

Requires the start process to have a reference flow (is_reference_flow = TRUE
exchange) -- if it doesn't, this returns zero rows, since there is no
functional unit to scale against.
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
--- supply_chain_inventory(start_process_id, target_amount, max_depth) ---
Aggregates elementary exchanges across the whole scaled chain into one row
per elementary flow -- the cradle-to-gate LCI. Every contributing amount is
converted into the flow's OWN default unit before summing (via
convert_amount()), so a flow recorded in different units at different
processes still aggregates into a single correct row instead of splitting
across unit-specific rows.

skipped_unconvertible_count on a row means: this many of the contributing
exchanges for this flow could not be converted into the flow's default unit
and were excluded from total_amount. 0 in the common case (exchange unit
already equals the flow's default unit).
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
--- calculate_cradle_to_gate_impacts(start_process_id, target_amount, max_depth) ---
The §5.2/§5.4 bridge: runs the cradle-to-gate inventory through the same
characterization logic as calculate_direct_impacts() (06_lcia_calculation.sql),
instead of just one process's direct exchanges.
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
