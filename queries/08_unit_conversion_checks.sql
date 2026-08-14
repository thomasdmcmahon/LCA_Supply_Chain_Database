/*
- LCA Supply Chain Database
- File: 08_unit_conversion_checks.sql
- Description: Exercises v_exchange_unit_flags and convert_amount() (schema/05_unit_conversions.sql) against whatever data is currently loaded.

Run with:
    docker compose exec -T postgres psql -U lca_user -d lca_supply_chain < queries/08_unit_conversion_checks.sql
*/

/*
UNIT STATUS BREAKDOWN
How many exchanges fall into each unit_status bucket. On the seed data alone,
expect everything to be 'matches_flow_default' (the seed data was hand-typed
consistently). After an ELCD load, expect some 'unit_missing' rows (exchanges
whose olca:unitId didn't resolve during transform) and possibly
'incompatible' rows once real cross-unit exchanges show up -- both are
informational, not errors.
*/
SELECT
    unit_status,
    COUNT(*) AS exchange_count
FROM v_exchange_unit_flags
GROUP BY unit_status
ORDER BY exchange_count DESC;

/*
INCOMPATIBLE EXCHANGES
The actual flag: exchanges whose unit cannot be reconciled with their flow's
default unit at all (not just "different unit", but genuinely unconvertible
given what's currently modeled in units.unit_group_external_id /
to_base_unit_factor). Worth reviewing by hand -- could be a genuine
dimensional mismatch in the source data, or simply a conversion group this
project hasn't populated real factors for yet (see the follow-up note in
schema/05_unit_conversions.sql for ELCD units specifically).
Expected on seed data alone: 0 rows.
*/
SELECT
    process_name,
    flow_name,
    exchange_unit_name,
    flow_default_unit_name
FROM v_exchange_unit_flags
WHERE unit_status = 'incompatible'
ORDER BY process_name, flow_name
LIMIT 50;

/*
CONVERT_AMOUNT() SANITY CHECK
Direct exercise of the conversion function against the seed units: 1000 kg
should equal 1 t; kWh <-> MJ should round-trip; a mass unit converted to an
energy unit should return NULL (not silently zero or wrong).
Expected: 1000.00..., 1.00..., 3.6000..., NULL
*/
SELECT
    convert_amount(1000, (SELECT id FROM units WHERE name = 'kg'), (SELECT id FROM units WHERE name = 't')) AS kg_1000_to_t,
    convert_amount(1, (SELECT id FROM units WHERE name = 't'), (SELECT id FROM units WHERE name = 'kg')) AS t_1_to_kg,
    convert_amount(1, (SELECT id FROM units WHERE name = 'kWh'), (SELECT id FROM units WHERE name = 'MJ')) AS kwh_1_to_mj,
    convert_amount(1, (SELECT id FROM units WHERE name = 'kg'), (SELECT id FROM units WHERE name = 'MJ')) AS kg_to_mj_should_be_null;
