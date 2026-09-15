/*
Unit conversion: which units can convert into which, a function that does it,
and a view that flags exchanges whose unit disagrees with their flow's.

Run after 01_create_tables.sql, 02_constraints.sql and 03_seed_data.sql.

The key decision is what makes two units compatible. The obvious answer is the
'dimension' column (both says "mass", so convert). That is unsafe: dimensions is
a label inferred from unit gorup names during transform, and two unrelated groups
can end up with the same label without sharing a reference point.

The real key is 'unit_group_external_id'. ILCD already carries this structure:
each unit group names one reference unit, and every other unit's meanValue is
its factor to that group's reference. Conversion is only every attempted withing
a group.

Known gap: load_to_postgres.py discards the unit group fields transform.py already
resolves, so ELCD-loaded units have NULL unit_group_external_id and convert_amount()
returns NULL for every pair of them. That is correct behavior (no group, no guess), but
it means the function is currently only excercised by the seed units. See the FOLLOW-UP
note below.
*/

ALTER TABLE units ADD COLUMN IF NOT EXISTS unit_group_external_id VARCHAR(255);
ALTER TABLE units ADD COLUMN IF NOT EXISTS to_base_unit_factor NUMERIC(38, 18);
ALTER TABLE units ADD COLUMN IF NOT EXISTS is_base_unit BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN units.unit_group_external_id IS
    'The real conversion-compatibility key: units are only convertible when this matches. For ELCD-loaded units this is the source ILCD unit group UUID; for hand-written seed units it is a synthetic slug (see UPDATE statements below). Do NOT use the free-text dimension column for conversion decisions -- see file header.';

COMMENT ON COLUMN units.to_base_unit_factor IS
    'Multiply an amount in this unit by this factor to get the amount in this unit''s conversion group base unit (the group''s is_base_unit = TRUE row).';

COMMENT ON COLUMN units.is_base_unit IS
    'TRUE for the one reference/base unit of its conversion group. At most one per unit_group_external_id (see idx_units_one_base_per_group).';

CREATE UNIQUE INDEX IF NOT EXISTS idx_units_one_base_per_group
    ON units(unit_group_external_id)
    WHERE is_base_unit = TRUE;

-- Seed units. Matched by name rather than id so this survives a change in
-- insertion order. The slugs are synthetic (no ILCD unit gorup backes the hand-written data),
-- but stable
UPDATE units SET unit_group_external_id = 'seed:mass', to_base_unit_factor = 1, is_base_unit = TRUE WHERE name = 'kg';
UPDATE units SET unit_group_external_id = 'seed:mass', to_base_unit_factor = 1000, is_base_unit = FALSE WHERE name = 't';
UPDATE units SET unit_group_external_id = 'seed:energy', to_base_unit_factor = 1, is_base_unit = TRUE WHERE name = 'MJ';
UPDATE units SET unit_group_external_id = 'seed:energy', to_base_unit_factor = 3.6, is_base_unit = FALSE WHERE name = 'kWh';
UPDATE units SET unit_group_external_id = 'seed:volume', to_base_unit_factor = 1, is_base_unit = TRUE WHERE name = 'm3';
UPDATE units SET unit_group_external_id = 'seed:transport', to_base_unit_factor = 1, is_base_unit = TRUE WHERE name = 'tkm';
UPDATE units SET unit_group_external_id = 'seed:item', to_base_unit_factor = 1, is_base_unit = TRUE WHERE name = 'p';
UPDATE units SET unit_group_external_id = 'seed:area', to_base_unit_factor = 1, is_base_unit = TRUE WHERE name = 'm2';

/*
FOLLOW-UP: wire load_to_postgres.py's upsert_units() to carry through what
transform.py already computes (source_unit_group_uuid into unit_group_external_id,
conversion_to_reference into to_base_unit_factor, and reference_unit_by_group_uuid
into is_base_unit). Both fields are resolved at transform time and dropped at load time.
 */

/*
Returns NULL rather than raising when a conversion cannot be done (whether the units
are unmodelled, in different groups, or genuinely incompatible). That lets callers filter
and count in ordinary set-based SQL instead of catching per-row expections, and it means
a wrong number can never come out of here.
*/
CREATE OR REPLACE FUNCTION convert_amount(
    p_amount NUMERIC,
    p_from_unit_id INT,
    p_to_unit_id INT
) RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_from_group VARCHAR(255);
    v_to_group VARCHAR(255);
    v_from_factor NUMERIC(38, 18);
    v_to_factor NUMERIC(38, 18);
BEGIN
    IF p_amount IS NULL OR p_from_unit_id IS NULL OR p_to_unit_id IS NULL THEN
        RETURN NULL;
    END IF;

    -- Same unit: nothing to do. This is the path most ELCD exchanges take,
    -- which is why the missing unit groups have not broken anything yet.
    IF p_from_unit_id = p_to_unit_id THEN
        RETURN p_amount;
    END IF;

    SELECT unit_group_external_id, to_base_unit_factor
    INTO v_from_group, v_from_factor
    FROM units WHERE id = p_from_unit_id;

    SELECT unit_group_external_id, to_base_unit_factor
    INTO v_to_group, v_to_factor
    FROM units WHERE id = p_to_unit_id;

    IF v_from_group IS NULL OR v_to_group IS NULL OR v_from_group <> v_to_group THEN
        RETURN NULL; -- different or unmodeled conversion groups: not convertible
    END IF;

    IF v_from_factor IS NULL OR v_to_factor IS NULL OR v_to_factor = 0 THEN
        RETURN NULL; -- same group but factors not populated: can't compute
    END IF;

    RETURN p_amount * v_from_factor / v_to_factor;
END;
$$;

COMMENT ON FUNCTION convert_amount(NUMERIC, INT, INT) IS
    'Convert an amount between two units. Returns the amount unchanged if the units are identical, the converted amount if they share a conversion group, or NULL if they are incompatible or unmodeled. Never raises for a data problem -- callers filter/count NULLs instead.';

CREATE OR REPLACE FUNCTION units_convertible(p_from_unit_id INT, p_to_unit_id INT)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    SELECT convert_amount(1, p_from_unit_id, p_to_unit_id) IS NOT NULL;
$$;

COMMENT ON FUNCTION units_convertible(INT, INT) IS
    'TRUE if convert_amount() could convert between these two units (same unit, or same conversion group with known factors).';


/*
Every exchange's unit against the flow's default. unit_status sorts them into
four buckets:

    matches_flow_default    same unit, nothing to do
    convertibale            diffrent unit, bridged (amount_in_flow_default_unit
                            is populated)
    incompatible            different unit, not bridgeable. either a real dimensional
                            mismatch in the source data or a conversion group with no factors yet
    unit_missing            exchagne or flow has no unit at all

The two causes behind 'incompatible' need a human to tell apart. See queries/08_unit_conversion_check.sql
*/
CREATE OR REPLACE VIEW v_exchange_unit_flags AS
SELECT
    e.id AS exchange_id,
    e.process_id,
    p.name AS process_name,
    e.flow_id,
    f.name AS flow_name,
    e.unit_id AS exchange_unit_id,
    eu.name AS exchange_unit_name,
    f.unit_id AS flow_default_unit_id,
    fu.name AS flow_default_unit_name,
    CASE
        WHEN e.unit_id IS NULL OR f.unit_id IS NULL THEN 'unit_missing'
        WHEN e.unit_id = f.unit_id THEN 'matches_flow_default'
        WHEN units_convertible(e.unit_id, f.unit_id) THEN 'convertible'
        ELSE 'incompatible'
    END AS unit_status,
    convert_amount(e.amount, e.unit_id, f.unit_id) AS amount_in_flow_default_unit
FROM exchanges e
JOIN processes p ON p.id = e.process_id
JOIN flows f ON f.id = e.flow_id
LEFT JOIN units eu ON eu.id = e.unit_id
LEFT JOIN units fu ON fu.id = f.unit_id;

COMMENT ON VIEW v_exchange_unit_flags IS
    'Every exchange''s unit compared against its flow''s default unit. Filter unit_status = ''incompatible'' to find exchanges that cannot be reconciled with their flow''s default unit -- a real data-quality issue worth investigating. See queries/08_unit_conversion_checks.sql.';
