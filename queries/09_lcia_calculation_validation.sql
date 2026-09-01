/*
- LCA Supply Chain Database
- File: 09_lcia_calculation_validation.sql
- Description: Validates the LCIA calculation engine (schema/06_lcia_calculation.sql) against the seed wheat-flour data, whose small size makes it hand-checkable.

Run with:
    docker compose exec -T postgres psql -U lca_user -d lca_supply_chain < queries/09_lcia_calculation_validation.sql

IMPORTANT: this does NOT reproduce the pre-existing hand-typed illustrative
impact_results values in 03_seed_data.sql (e.g. wheat farming GWP100 =
0.350). Those numbers were typed by hand as placeholders and were never
derived from the seed exchanges -- among other things they implicitly assume
upstream/background emissions (e.g. N2O from fertilizer breakdown) that
aren't modeled as explicit exchanges anywhere in the seed data, so no
correct engine could reproduce them from the visible exchange list. What
this file validates instead is that the engine correctly implements "sum of
characterized elementary exchanges" against a hand-computed expectation --
see the comments above each query for the exact expected numbers, computed
independently in Python and reproduced in
loader/validate_lcia_seed.py.

Only 4 characterization_factors are seeded (04_characterization_factors.sql):
CO2 -> GWP100, Phosphate -> EP, Ammonia -> Acidification (AE),
Nitrogen oxides -> Acidification (AE). Everything else (Nitrate, Water
river, and all of CED) is intentionally uncharacterized -- see that file's
header for why.
*/

/*
DIRECT IMPACTS PER SEED PROCESS
Expected (hand-computed, exact):
    Wheat farming (process 1):   GWP100 = 0.00013         AE = 0.008456          EP = 0.00014
    Lorry transport (process 2): GWP100 = 0.000095         AE = 0.0000004588      (no EP row -- no phosphate exchange on this process)
    Flour milling (process 3):   GWP100 = 0.0000095         (no AE or EP row -- only CO2 is characterized on this process)
characterized_exchange_count / skipped_exchange_count should show 0 skipped
for all rows -- every seed exchange unit already matches its CF's unit.
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
PERSIST DIRECT IMPACTS
Run the bulk upsert, then show what landed in impact_results for the seed
processes. Note this OVERWRITES the pre-existing hand-typed GWP100/EP/AP
values for processes/categories the engine actually computed (see header) --
the AE category is new, so those rows are new inserts, not overwrites. CED
and the untouched-by-CFs 'AP' rows keep their original hand-typed values
since the engine has nothing to compute for them.
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
COVERAGE GAP
Elementary flows used in the seed data with no characterization factor at
all. Expected: Nitrate (to water) and Water, river -- exactly the two
flows 04_characterization_factors.sql's header documents as deliberately
unsourced.
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
