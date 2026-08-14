/*
- LCA Supply Chain Database
- File: 10_supply_chain_rollup_examples.sql
- Description: Exercises the generic recursive rollup (schema/07_supply_chain_rollup.sql) against the seed wheat-flour chain, cross-checked against the manual example in queries/06_supply_chain_graph.sql.

Run with:
    docker compose exec -T postgres psql -U lca_user -d lca_supply_chain < queries/10_supply_chain_rollup_examples.sql
*/

/*
SCALED PROCESS TRAVERSAL
Same traversal as queries/06_supply_chain_graph.sql's first query, but
generic and with automatically computed scaling factors instead of a
manually written VALUES list.
Expected: 3 rows.
    depth 0: Flour milling, wheat, RER      cumulative_scale = 1.00
    depth 1: Wheat farming, conventional, RER cumulative_scale = 1.35
    depth 1: Transport, lorry >32t, RER     cumulative_scale = 0.27
(matches queries/06_supply_chain_graph.sql's hand-written scale VALUES list exactly)
*/
SELECT
    depth,
    process_name,
    cumulative_scale,
    path
FROM supply_chain_scaled_processes(
    3,      -- Flour milling, wheat, RER
    1.0,    -- target: 1 kg flour
    50      -- max_depth (default shown explicitly)
)
ORDER BY depth, process_name;

/*
CRADLE-TO-GATE INVENTORY
The automatic equivalent of queries/06_supply_chain_graph.sql's second query
(the manual VALUES-based rollup). Expected (hand-computed, exact):
    Carbon dioxide, fossil : 0.00021065  kg
    Ammonia                : 0.003780   kg
    Nitrate, to water       : 0.002565   kg
    Phosphate, to water     : 0.0001890  kg
    Water, river            : 0.5670     m3
    Nitrogen oxides          : 0.0000001674 kg
skipped_unconvertible_count should be 0 for every row (seed units already
consistent).
*/
SELECT
    flow_name,
    unit_name,
    total_amount,
    skipped_unconvertible_count
FROM supply_chain_inventory(3, 1.0)
ORDER BY total_amount DESC;

/*
CRADLE-TO-GATE IMPACTS
Feeds the inventory above through the same characterization logic as
calculate_direct_impacts() (queries/09_lcia_calculation_validation.sql).
Expected (hand-computed, exact):
    GWP100 (CML 2002) = 0.00021065
    AE (ILCD 2011)    = 0.011415723876
    EP (CML 2002)     = 0.0001890
Compare GWP100 against summing the three per-process direct results from
queries/09 scaled by cumulative_scale by hand:
    (0.0000095 * 1) + (0.00013 * 1.35) + (0.000095 * 0.27) = 0.00021065  -- matches.
*/
SELECT
    ic.code AS impact_category,
    ic.method,
    calc.value,
    calc.characterized_flow_count,
    calc.skipped_flow_count
FROM calculate_cradle_to_gate_impacts(3, 1.0) AS calc
JOIN impact_categories ic ON ic.id = calc.impact_category_id
ORDER BY ic.code;

/*
DEPTH CAP / CYCLE SAFETY SMOKE TEST
The seed data has no cycles, so this just confirms a very low max_depth
truncates the traversal rather than erroring -- with max_depth = 0 only the
anchor (Flour milling itself) should come back.
Expected: 1 row (Flour milling, wheat, RER, depth 0).
*/
SELECT depth, process_name
FROM supply_chain_scaled_processes(3, 1.0, 0)
ORDER BY depth;
