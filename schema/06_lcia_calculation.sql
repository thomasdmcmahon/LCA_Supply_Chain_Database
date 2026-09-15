/*
The LCIA calculation engine: turns exchanges into impact scores by multiplying
each elementary amount by its characterization factor.

This file handles direct impacts (only the exchanges recorded on the process itself).
For a whole upstream chain, see caclulcate_cradle_to_gate_impacts() in 07_supply_chain_rollup.sql,
which runs a scaled inventory through the same logic.

Run after 01 through 05.

On overwriting: upsert_direct_impacts_for_all_processes() replaces existing
impact_results values for every (process, category) pair it computes. The seed
data's hand-typed numbers for GWP100 and EP are overwritten. What survives is
categories with no factors at all (CML's 'AP' and 'CED) because the engine never
produces a row for them.

Run with:
    docker compose exec -T postgres psql -U lca_user -d lca_supply_chain \
        -c "CALL upsert_direct_impacts_for_all_processes();"
    make calculate-impacts
*/

/*
One row per impact category the process has at least one characterized exchange for.
Read-only.

    characterized_exchange_count  contributed to value
    skipped_exchange_count        had a factor, but the units would not convert

Neither counts exchanges with no factor at all — those never enter the join.
See v_elementary_flows_without_cf at the bottom for that gap.
*/
CREATE OR REPLACE FUNCTION calculate_direct_impacts(p_process_id INT)
RETURNS TABLE (
    impact_category_id INT,
    value NUMERIC,
    characterized_exchange_count INT,
    skipped_exchange_count INT
)
LANGUAGE sql
STABLE
AS $$
    WITH contributions AS (
        SELECT
            cf.impact_category_id AS impact_category_id,
            convert_amount(e.amount, e.unit_id, cf.unit_id) AS amount_in_cf_unit,
            cf.factor AS factor
        FROM exchanges e
        JOIN flows f
            ON f.id = e.flow_id
            AND f.flow_type = 'elementary'
        JOIN characterization_factors cf
            ON cf.flow_id = e.flow_id
        WHERE e.process_id = p_process_id
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

COMMENT ON FUNCTION calculate_direct_impacts(INT) IS
    'Direct (non-recursive) LCIA impacts for one process: elementary exchange amount x characterization factor, grouped by impact category. Read-only -- see upsert_direct_impacts() to persist.';


/*
Persists the above for one process. Skips categories where the value came out
NULL, so a failed conversion leaves the existing row alone rather than replacing
it with nothing.
*/
CREATE OR REPLACE PROCEDURE upsert_direct_impacts(p_process_id INT)
LANGUAGE sql
AS $$
    INSERT INTO impact_results (process_id, impact_category_id, value)
    SELECT p_process_id, calc.impact_category_id, calc.value
    FROM calculate_direct_impacts(p_process_id) AS calc
    WHERE calc.value IS NOT NULL
    ON CONFLICT (process_id, impact_category_id)
    DO UPDATE SET value = EXCLUDED.value, created_at = NOW();
$$;

COMMENT ON PROCEDURE upsert_direct_impacts(INT) IS
    'Persist calculate_direct_impacts() for one process into impact_results (upsert on process_id, impact_category_id).';


/*
The same thing for every process, as one statement rather than a loop (at 611 processes
and 212k exhanges, a per-process loop would mean 611 separate queries).

Safe to rerun: it uperts on (process_id, impact_category_id), the same don't duplicate
pattern the loader uses.

Note convert_amount() appears twice, in the SUM and in the WHERE. Postgres evaluates
both, so each qualifying row converts twice. Correct but wasteful (a lateral or a CTE could
do it once).
*/
CREATE OR REPLACE PROCEDURE upsert_direct_impacts_for_all_processes()
LANGUAGE sql
AS $$
    INSERT INTO impact_results (process_id, impact_category_id, value)
    SELECT
        e.process_id,
        cf.impact_category_id,
        SUM(convert_amount(e.amount, e.unit_id, cf.unit_id) * cf.factor)
    FROM exchanges e
    JOIN flows f
        ON f.id = e.flow_id
        AND f.flow_type = 'elementary'
    JOIN characterization_factors cf
        ON cf.flow_id = e.flow_id
    WHERE convert_amount(e.amount, e.unit_id, cf.unit_id) IS NOT NULL
    GROUP BY e.process_id, cf.impact_category_id
    ON CONFLICT (process_id, impact_category_id)
    DO UPDATE SET value = EXCLUDED.value, created_at = NOW();
$$;

COMMENT ON PROCEDURE upsert_direct_impacts_for_all_processes() IS
    'Persist calculate_direct_impacts() for every process in one set-based statement. Safe to rerun (upsert on process_id, impact_category_id); only writes (process, category) pairs with at least one characterized, unit-convertible exchange.';


/*
What the engine cannot score: elementary flows used in at least one exchange with
no characterization factor in any category.

Expect this to be long after an ELCD load (only four flows are seeded). That is the
documented state, not a bug, and this view is how to see exactly what sourcing work remains.
*/
CREATE OR REPLACE VIEW v_elementary_flows_without_cf AS
SELECT DISTINCT
    f.id AS flow_id,
    f.name AS flow_name,
    f.external_id,
    f.unit_id,
    u.name AS unit_name
FROM flows f
LEFT JOIN units u ON u.id = f.unit_id
WHERE f.flow_type = 'elementary'
  AND EXISTS (SELECT 1 FROM exchanges e WHERE e.flow_id = f.id)
  AND NOT EXISTS (SELECT 1 FROM characterization_factors cf WHERE cf.flow_id = f.id);

COMMENT ON VIEW v_elementary_flows_without_cf IS
    'Elementary flows used in at least one exchange with zero characterization_factors coverage (any category). Companion to calculate_direct_impacts()''s skipped_exchange_count, which only counts flows that HAVE a factor but failed unit conversion -- this view is for flows that have no factor at all.';
