/*
Impact results joined their process and category and ranked within each category.

What the rankings mean: every score is per that process' own reference flow, so the numbers rank contribution per functional unit, not which process is "worse". 1 kg of flour and 1 tonne-kilometre of transport are different questions.

Counts here depend on how much of the LCIA engine has been run - see make calculate-impacts.

Run with:
    docker compose exec -T postgres psql -U lca_user -d lca_supply_chain < queries/05_impact_results_ranked.sql
*/

/*
Every stored score with its category and unit
*/
SELECT
    ic.code AS category,
    ic.method,
    ic.unit AS impact_unit,
    p.name AS process,
    ir.value
FROM impact_results ir
    JOIN processes p ON p.id = ir.process_id
    JOIN impact_categories ic ON ic.id = ir.impact_category_id
ORDER BY ic.id, ir.value DESC;

/*
Ranked within each category. Partitioned in impact_category_id rather than code, because the same code under a different method is a different indicator in a different unit (CML's AP (kg SO2-eq) and ILCD's AE (molc H+-eq) must never share a ranking).
*/
SELECT
    ic.code AS category,
    ic.unit AS impact_unit,
    RANK() OVER (
        PARTITION BY ir.impact_category_id
        ORDER BY ir.value DESC
    ) AS rank,
    p.name AS process,
    ir.value
FROM impact_results ir
    JOIN processes p ON p.id  = ir.process_id
    JOIN impact_categories ic ON ic.id = ir.impact_category_id
ORDER BY ic.id, rank;

/*
The largest contributor per category. Ties return multiple rows, which is correct - the subquery matches on value, not on a single row.
*/
SELECT
    ic.code AS category,
    ic.name AS category_name,
    ic.unit AS impact_unit,
    p.name AS highest_scoring_process,
    ir.value
FROM impact_results ir
    JOIN processes p ON p.id = ir.process_id
    JOIN impact_categories ic ON ic.id = ir.impact_category_id
WHERE ir.value = (
    SELECT MAX(ir2.value)
    FROM impact_results ir2
    WHERE ir2.impact_category_id = ir.impact_category_id
)
ORDER BY ic.id;