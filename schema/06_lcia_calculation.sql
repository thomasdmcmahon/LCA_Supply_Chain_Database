/*
- LCA Supply Chain Database
- File: 06_lcia_calculation.sql
- Description: LCIA calculation engine. Derives impact_results from
  exchanges x characterization_factors instead of the hand-entered seed
  values, using convert_amount() (05_unit_conversions.sql) wherever an
  exchange's unit differs from its characterization factor's unit.

Run after 01_create_tables.sql, 02_constraints.sql, 03_seed_data.sql,
04_characterization_factors.sql, and 05_unit_conversions.sql.

This covers *direct* (single-process, gate-to-gate) impacts: only the
exchanges recorded directly on a process. For cradle-to-gate impacts across
an upstream supply chain, see calculate_cradle_to_gate_impacts() in
07_supply_chain_rollup.sql, which feeds a scaled upstream inventory through
the same characterization logic as this file.

Nothing here is destructive: upsert_direct_impacts_for_all_processes() only
writes rows for (process, impact_category) pairs it actually computed a
value for. impact_results rows for categories with no characterization_factors
coverage at all (e.g. the seed data's original CML 'AP'/'CED' rows -- see
04_characterization_factors.sql) are never touched by this engine and keep
whatever value they already had.

Run with:
    docker compose exec -T postgres psql -U lca_user -d lca_supply_chain \
        -c "CALL upsert_direct_impacts_for_all_processes();"
    make calculate-impacts
*/

/*
--- calculate_direct_impacts(process_id) ---
Read-only. Returns one row per impact category the process has at least one
characterized elementary exchange for.

  characterized_exchange_count -- exchanges with a matching CF whose units
                                   converted successfully and contributed to
                                   `value`.
  skipped_exchange_count       -- exchanges with a matching CF whose units
                                   could NOT be converted (convert_amount()
                                   returned NULL); excluded from `value`.

Note this does NOT count elementary exchanges with no CF row at all -- those
never enter this function's join to begin with. See
v_elementary_flows_without_cf below for that coverage gap.
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
--- upsert_direct_impacts(process_id) ---
Persists calculate_direct_impacts() for one process into impact_results.
Only writes categories with a non-NULL computed value; existing rows for
categories this process has no CF coverage for are left untouched.
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
--- upsert_direct_impacts_for_all_processes() ---
Set-based equivalent of calling upsert_direct_impacts() for every process --
built as one query rather than a per-process loop so it stays fast at ELCD
scale (608 processes, 212k exchanges). This is the "rerunnable like the
loader" entry point: safe to call repeatedly, matches the loader's own
upsert-don't-duplicate pattern.
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
--- COVERAGE DIAGNOSTICS ---
*/

-- Elementary flows that are actually used in at least one exchange but have
-- no characterization_factors row at all, for ANY impact category. Expect
-- this to be large for the full ELCD load (04_characterization_factors.sql
-- seeds only 4 flows total) -- that's the expected, documented state, not a
-- bug. Use this view to see exactly what's missing before sourcing more
-- factors.
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
