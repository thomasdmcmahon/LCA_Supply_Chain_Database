/*
Excercises v_exchange_unit_flags and convert_amount() (schema/05_unit_conversions.sql) against whatever is currently loaded.

Worth knowing before reading the output: load_to_postgres.py does not yet populate units.unit_group_external_id for ELCD units, so convert_amount() returns NULL for any pair of them. That is the designed behaviour (no conversion groups, no guess), but it means the checks below mostly excercise the seed units until that loader work is done.

Run with:
    docker compose exec -T postgres psql -U lca_user -d lca_supply_chain < queries/08_unit_conversion_checks.sql
    make check-units
*/

/*
How exchanges distrbute across the four unit_status buckets.

Seed data alone: all 'matches_flow_default', sice it was typed consistently by hand. After an ELCD loda, expect 'unit_missing' rows where the transform could not resolve a unit, and 'incompatible' rows for cross-unit exchanges. Neither is an arror, both are the view doing its job.
*/
SELECT
    unit_status,
    COUNT(*) AS exchange_count
FROM v_exchange_unit_flags
GROUP BY unit_status
ORDER BY exchange_count DESC;

/*
The flag itself: exchanges whose unit cannot be reconciled with the flow's default at all. Two different causes sit in this bucket, and telling them apart needs a human:

- a genuine dimensional mismatch in the source data, which is a real data quality problem
- a conversion group this project has not populated factors for, which is just unfinished work

Expected on seed data alone: 0 rows
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
The function itself, against the seed units. The last one is the important case: a mass unit converted to an energy unit must return NULL rather than a plausible-looking number.

Expected: 1, 1000, 3.6, NULL
*/
SELECT
    convert_amount(1000, (SELECT id FROM units WHERE name = 'kg'), (SELECT id FROM units WHERE name = 't')) AS kg_1000_to_t,
    convert_amount(1, (SELECT id FROM units WHERE name = 't'), (SELECT id FROM units WHERE name = 'kg')) AS t_1_to_kg,
    convert_amount(1, (SELECT id FROM units WHERE name = 'kWh'), (SELECT id FROM units WHERE name = 'MJ')) AS kwh_1_to_mj,
    convert_amount(1, (SELECT id FROM units WHERE name = 'kg'), (SELECT id FROM units WHERE name = 'MJ')) AS kg_to_mj_should_be_null;