/*
Validates the LCIA calculation engine (schema/06_lcia_calculation.sql) against the seed wheat-flour data, which is small enough to check by hand.

!Warning: this file is not read-only. It calls upsert_direct_imapcts_for_all_procesess(), which rewrites impact_results for every process in the database, not just the seed ones.

What it does NOT do is reproduce the hand-typed illustrative values in 03_seed_data.sql (wheat farming GWP=100 = 0.350 and so on). Those were placeholders, never dervived from the seed exchanges (they implicitly assume background emissions like N20 from fertilizer breakdown that are not modeled as exchanges anywhere). No correct engine could arrive at them from the visible data. What is validated here is that the engine implements "sum of characterized elementary exchanges" correctly, against expectations computed independently in Python (loader/validate_lcia_seed.py).

Only four factors are seeded (04_characterization_factors.sql):
CO2 -> GWP100, Phosphate -> EP, Ammonia and Nitrogen oxides -> AE. Nitrate, Water river and all of CED are delibaretly uncharacterized.

Run with:
    docker compose exec -T postgres psql -U lca_user -d lca_supply_chain < queries/09_lcia_calculation_validation.sql
    make validate-lcia
*/

/*
Direct impacts per seed process. Each number is amount x factor, so they can be checked against 03_seed_data.sql and 04_characterisation_factors.sql by hand:

  Wheat farming    GWP100  0.00013      = 0.00013 CO2 x 1
                   AE      0.008456     = 0.0028 ammonia x 3.02
                   EP      0.00014      = 0.00014 phosphate x 1
  Lorry transport  GWP100  0.000095     = 0.000095 CO2 x 1
                   AE      0.0000004588 = 0.00000062 NOx x 0.74
  Flour milling    GWP100  0.0000095    = 0.0000095 CO2 x 1

Missing rows are correct: a process only appears for a category it has a characterized exchange in. skipped_exchange_count should be 0 throughout. Every seed exchange already uses its factor's unit, so no conversion is attempted.
*/
SELECT
    p.name AS process,
    ic.code AS impact_category,
    calc.value,
    calc.characterized_exchange_count,
    calc.skipped_exchange_count
FROM processes p
CROSS JOIN LATERAL calculate_direct_impacts(p.id) AS calc
JOIN impact_categories ic ON ic.id = calc.impact_category_id
WHERE p.source_dataset = 'Seed data (illustrative)'
ORDER BY p.id, ic.code;

/*
Persist, then read back. This overwrites the hand-typed values for every (process, category) pair the engine computed. AE rows are new inserts, since that category did not exist in the seed data. CML's AP and CED keep their original hand-typed values (the engine has no factor for them, so it never writes those rows).
*/
CALL upsert_direct_impacts_for_all_processes();

SELECT
    p.name AS process,
    ic.code AS impact_category,
    ic.method,
    ir.value,
    ir.created_at
FROM impact_results ir
    JOIN processes p ON p.id = ir.process_id
    JOIN impact_categories ic ON ic.id = ir.impact_category_id
WHERE p.source_dataset = 'Seed data (illustrative)'
ORDER BY p.id, ic.code;

/*
The coverage gap, scoped to seed data. Expected: Nitrate (to water) and Water, river (the two flows 04_characterization_factors.sql) documents as deliberately unsourced). Seeing exactly those two, and nothing else, confirms the documentation matches the data.
*/
SELECT flow_name, unit_name
FROM v_elementary_flows_without_cf
WHERE flow_id IN (
    SELECT DISTINCT e.flow_id
    FROM exchanges e
    JOIN processes p ON p.id = e.process_id
    WHERE p.source_dataset = 'Seed data (illustrative)'
)
ORDER BY flow_name;