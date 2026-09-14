/*
Excercises the generic rollup (schema/07_supply_chain_rollup.sql) against the seed wheat-flour chain, cross-checked against the hand-written version in queries/06_supply_chain_graph.sql. The point is that the two agree: the generic functions derive from the schema what the manual query typed in.

Run with:
    docker compose exec -T postgres psql -U lca_user -d lca_supply_chain < queries/10_supply_chain_rollup_examples.sql
    make validate-lcia
*/

/*
The traversal, with scaling factors computed rather than typed.
Expected: 3 rows.
    depth 0  Flour milling              1.00
    depth 1  Wheat farming              1.35   (1.35 kg grain per kg flour)
    depth 1  Lorry transport            0.27   (0.27 tkm per kg flour)
Matching queries/06's hand-written VALUES list exactly — that agreement is
the actual test here.
*/
SELECT
    depth,
    process_name,
    cumulative_scale,
    path
FROM supply_chain_scaled_processes(
    3,      -- Flour milling, wheat, RER
    1.0,    -- target: 1 kg flour
    50      -- max_depth (default, shown for clarity)
)
ORDER BY depth, process_name;

/*
Cradle-to-gate inventory: every upstream emission scaled and summer per susbtance. Each figure is the process amount times its scale, so they can be checked by hand against 03_seed_data.sql:

    CO2                0.00021065   = 0.0000095 + 0.00013x1.35 + 0.000095x0.27
    Ammonia            0.003780     = 0.0028 x 1.35
    Nitrate, to water  0.002565     = 0.0019 x 1.35
    Phosphate          0.0001890    = 0.00014 x 1.35
    Water, river       0.5670       = 0.42 x 1.35
    Nitrogen oxides    0.0000001674 = 0.00000062 x 0.27

skipped_unconvertible_count should be 0 throughout, seed units are already consistent, so no conversion is attempted.
*/
SELECT
    flow_name,
    unit_name,
    total_amount,
    skipped_unconvertible_count
FROM supply_chain_inventory(3, 1.0)
ORDER BY total_amount DESC;

/*
The inventory above characterized, using the same logic as calculate_direct_impacts(). Expected:
    GWP100 (CML 2002)  0.00021065
    AE (ILCD 2011)     0.0114157239
    EP (CML 2002)      0.0001890

Note what is missing and why: nitrate and water have no factor, so eutrophication here covers only phosphate, and the water flow contributes nothing at all. The numbers are correct for what is characterized, not complete for the product.
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
Depth cap. With max_depth = 0 only the anchor comes back, and the traversal truncates rather than erroring.

This does not test the cycle guard. The seed data is a tree, so NOT (upstream.id = ANY(path)) never fires here (testing it would need a constructed cycle, which is on the list rather than done).

Expected: 1 row, Flour milling at depth 0
*/
SELECT depth, process_name
FROM supply_chain_scaled_processes(3, 1.0, 0)
ORDER BY depth;