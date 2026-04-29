/*
- LCA Supply Chain Database
- File: 05_impact_results_ranked.sql
- Description: Joins pre-calculated LCIA scores to impact categories and ranks processes within each category. Shows which process contributes most to each environmental metric.

Run with:
    docker compose exec -T postgres psql -U lca_user -d lca_supply_chain < queries/05_impact_results_ranked.sql
*/

/*
ALL IMPACT RESULTS WITH CONTEXT
Full join on impact_results to processes and impact_categories.
-- Expected: 12 rows (4 processes x 3 impact categories)
*/
SELECT
    ic.code AS category,
    ic.unit AS impact_unit,
    p.name AS process,
    ir.value
FROM impact_results ir
    JOIN processes p ON p.id = ir.process_id
    JOIN impact_categories ic ON ic.id = ir.impact_category_id
ORDER BY ic.id, ir.value DESC;

/*
PROCESSES RANKED BY IMPACT WITHIN EACH CATEGORY
Uses RANK() to order processes from highest to lowest score per category. A rank of 1 means that process is the largest contributor to that metric.
-- Expected: 12 rows
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
HIGHEST IMPACT PROCESS PER CATEGORY
Filters to rank = 1 only, giving the single worst process for each metric.
-- Expected: 4 rows, one per impact category
*/
SELECT
    ic.code AS category,
    ic.name AS category_name,
    ic.unit AS impact_unit,
    p.name AS worst_process,
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