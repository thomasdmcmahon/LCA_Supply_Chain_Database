/*
- LCA Supply Chain Database
- File: 05_unit_conversions.sql
- Description: Unit compatibility/conversion model, plus a conversion
  function and a flagging view for exchanges whose unit doesn't match their
  flow's default unit.

Run after 01_create_tables.sql, 02_constraints.sql, and 03_seed_data.sql.

DESIGN
Units are convertible only within the same "conversion group" -- the real
compatibility key is `unit_group_external_id`, NOT the free-text `dimension`
column. `dimension` (mass/energy/volume/...) is a best-effort human-readable
label inferred from unit group names during ELCD transform and is NOT safe
to use for conversion math: two differently-sourced unit groups could both
get labeled "mass" by that inference without sharing a reference unit.
`unit_group_external_id` instead tracks the actual ILCD unit group (or, for
hand-written seed units, a synthetic slug -- see UPDATE below), so conversion
is only ever attempted between units that are known to share one reference
point.

Within a conversion group, `to_base_unit_factor` says: multiply an amount in
this unit by this factor to get the amount in the group's base unit.
Exactly one unit per group should have `is_base_unit = TRUE` (factor 1 by
construction, though this isn't enforced beyond convention + the partial
unique index below).

For ELCD-loaded units, this is not invented: ILCD unit groups already carry
this exact structure (referenceToReferenceUnit + each unit's meanValue is
"how many reference-units equal 1 of this unit" -- confirmed against the
XML files in data/raw/elcd_3_2/exported/ilcd/ILCD/unitgroups). transform.py already resolves this
per unit (`source_unit_group_uuid`, `conversion_to_reference`) but
load_to_postgres.py currently discards both fields; wiring that through is
listed as follow-up work below so this file can ship the schema/function
independent of that loader change.
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

-- Populate the hand-written seed units (schema/03_seed_data.sql). Matched by
-- name, not id, so this stays correct regardless of insertion order. Slugs
-- are synthetic (no ILCD unit group backs the seed data) but stable.
UPDATE units SET unit_group_external_id = 'seed:mass', to_base_unit_factor = 1, is_base_unit = TRUE WHERE name = 'kg';
UPDATE units SET unit_group_external_id = 'seed:mass', to_base_unit_factor = 1000, is_base_unit = FALSE WHERE name = 't';
UPDATE units SET unit_group_external_id = 'seed:energy', to_base_unit_factor = 1, is_base_unit = TRUE WHERE name = 'MJ';
UPDATE units SET unit_group_external_id = 'seed:energy', to_base_unit_factor = 3.6, is_base_unit = FALSE WHERE name = 'kWh';
UPDATE units SET unit_group_external_id = 'seed:volume', to_base_unit_factor = 1, is_base_unit = TRUE WHERE name = 'm3';
UPDATE units SET unit_group_external_id = 'seed:transport', to_base_unit_factor = 1, is_base_unit = TRUE WHERE name = 'tkm';
UPDATE units SET unit_group_external_id = 'seed:item', to_base_unit_factor = 1, is_base_unit = TRUE WHERE name = 'p';
UPDATE units SET unit_group_external_id = 'seed:area', to_base_unit_factor = 1, is_base_unit = TRUE WHERE name = 'm2';

-- FOLLOW-UP (not done here): wire load_to_postgres.py's upsert_units() to
-- populate unit_group_external_id from each unit's source_unit_group_uuid
-- and to_base_unit_factor from its conversion_to_reference (both already
-- computed in transform.py, both currently discarded at load time), and
-- is_base_unit from whether the unit is its group's reference unit
-- (transform.py's reference_unit_by_group_uuid). Until that's done, ELCD-
-- loaded units have NULL unit_group_external_id and convert_amount() below
-- will correctly return NULL (unconvertible/unmodeled) for all of them
-- rather than guessing.


/*
--- CONVERSION FUNCTION ---
Returns NULL (never raises) when a conversion can't be performed -- same
unit, different-but-unmodeled units, or a genuine dimensional mismatch all
collapse to NULL so callers can filter/count in a single set-based query
instead of catching per-row exceptions. See v_exchange_unit_flags below and
calculate_direct_impacts (06_lcia_calculation.sql) for how callers use this.
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
--- FLAGGING VIEW ---
Every exchange compared against its flow's default unit. unit_status is the
actionable column:
  matches_flow_default -- unit_id equals the flow's default unit_id (the
                           common case, no conversion needed).
  convertible           -- different unit, but convert_amount() can bridge it
                           (amount_in_flow_default_unit is populated).
  incompatible          -- different unit, not convertible: either a genuine
                           dimensional mismatch or an unmodeled conversion
                           group (see follow-up note above for ELCD units).
                           This is the flag the roadmap asks for -- query
                           for unit_status = 'incompatible' to find them.
  unit_missing          -- exchange or flow has no unit_id at all.
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
