/*
Characterization factors: the multipliers that turn an emission amount into a
contribution to an impact category. 2 kg of methane at a GWP100 factor of 28
contributes 56 kg CO2-eq.

This file defines the table and seeds a handful of real, cited factors. Enough
to prove the calculation engine works end to end on the small wheat-flour example,
and no further.

Run after 01_create_tables.sql, 02_constraints.sql and 03_seed_data.sql.

!!WHAT THIS FILE DOES NOT DO!!

A factor with no traceable source invalidates everything computed from it,
so only sources numbers go in. That leaves real gaps, on purpose:

    - Coverage extends only to the elementary flows in the seed data: CO2,
    ammonia, nitrogen oxides and phosphate. Nitrate (eutrophication) and
    "Water, river" (a resource flow with no matching impact category here)
    are left uncharacterized (no verified source was found for nitrate, and
    guessing is worse than leaving it visibly blank). The view v_elementary_flows_withtout_cf,
    defined in 06_lcia_calculation,sql, lists what is missing at query time.

    - Cumulative energy demand (code 'CED') gets no factors at all. CED is characterized
    on resource extraction flows (crude oil in ground, hard coal in ground, each with no
    calorific-value factor) not on on the emissions the seed data models. None of those resoruce
    flows exist here, so there is nothing correct to characterize.

    - Nothing here covers the ELCD 3.2 load, whose flows are almost entirely uncharacterized.
    Bulk-sourcing factors for it (from the ILCD 2011 Recmonneded LCIA methods database (JRC, cited below))
    or a licensed method (is future work). Note that it is sourcing work, not coding: ELCD ships
    several separate flow rows for the same substance, matched only by CAS numbers, so each ahs to be
    mapped deliberately.

SOURCES

    - GWP100, fossil CO2 = 1 kg CO2-eq/kg. Definitional: CO2 is the reference substance for
    every GWP100 variant (IPCC, CML, ReCiPe), so the value is not method-specific.

    - Eutrophication, phosphate = 1 kg PO4-eq/kg. Definitional in the same way:
    this porject's 'EP' category is expressed in kg PO4-equivalents and phosphate
    is that indicator's own reference substance.

    - Acidification, ammonia = 3.02 molc H+-eq/kg; nitrogen oxides = 0.74 molc H+-EQ/kg
    (mapped fromn the standard "NOx as NO2" convention, the same one the source applies
    to "sulphur oxides as SO2").

    These are NOT CML 2002 kg-SO2-eq factors. Secondary sources for CML 2002 acification disagreed
    on ammonia (1.6 vs 1.88 kg SO2-eq/kg depening on which source) with no way to adjudicate between
    them, so none were used. These use the EU JRC's own recommended Accumulated Exceedeance method
    instead, which ships a fully derived, citable table:

        European Commission, Joint Research Centre, Institute for Environment
          and Sustainability (2012). "Characterisation factors of the ILCD
          Recommended Life Cycle Impact Assessment methods — Database and
          Supporting Information", 1st edition, EUR 25167 EN, section 3.6,
          Table 3 (derived from Posch et al., 2008), doi:10.2788/60825.
          https://eplca.jrc.ec.europa.eu/uploads/LCIA-characterization-factors-of-the-ILCD.pdf

    Becuae the unit differs from the seed 'AP' category's kg SO2-eq, these attach to a new
    impact_categories_row ('AE' / ILCD 2001) rather than being forced into the CML row.
    The method changed to match the source that could be verified, rather than the source being
    picked to fit a method actually assumed. The original 'AP' row keeps no factors at all.
*/

CREATE TABLE IF NOT EXISTS characterization_factors (
    id SERIAL PRIMARY KEY,

    -- The method is implied by the category (impact_categories.method), so
    -- one factor per (category, flow) pair is enough. A different method
    -- means a different category row, not a second factor here.
    impact_category_id INT NOT NULL REFERENCES impact_categories(id) ON DELETE CASCADE,

    -- Must be an elementary flow. Enforced by the trigger below rather than
    -- a CHECK, since CHECK cannot reference another table.
    flow_id INT NOT NULL REFERENCES flows(id) ON DELETE CASCADE,

    -- Multiply one unit_id of this flow by this to get one unit of the
    -- category's indicatior. NUMERIC(60, 50) matches exchanges.amount so a
    -- factor published at LCA-scale precision is not truncated here either.
    factor NUMERIC(60, 50) NOT NULL,

    -- The unit the factor is published per, which is not always the flow's default.
    -- Keep explicit rather than assumed; the calculation engine reconciles the two
    -- via convert_amount() (05_unit_conversion.sql).
    unit_id INT REFERENCES units(id) ON DELETE SET NULL,

    -- Citation. Deliberately not NOT NULL: a row without one should look unverified
    -- rather than be impossible to insert.
    source TEXT,

    -- TRUE for a stand-in rather than a published value. Every row this file
    -- seeds is FALSE. Kept for future bulk loading, where placeholders may be
    -- unavoidable and must stay visibly flagged.
    is_placeholder BOOLEAN NOT NULL DEFAULT FALSE,

    notes TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- One factor per elementary flow per impact category. If a method needs
    -- to diverge from another method's factor for the same flow, that's a
    -- different impact_categories row (different method), not a second row
    -- here.
    UNIQUE (impact_category_id, flow_id)
);

CREATE INDEX IF NOT EXISTS idx_characterization_factors_flow
    ON characterization_factors(flow_id);

CREATE INDEX IF NOT EXISTS idx_characterization_factors_category
    ON characterization_factors(impact_category_id);

-- Characterizing a product or waste flow is meaningless (impacts come from
-- what cross into nature). A CHECK cannot look at flows.flow_type, so this
-- is a trigger.
CREATE OR REPLACE FUNCTION trg_characterization_factor_flow_is_elementary()
RETURNS TRIGGER AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM flows
        WHERE id = NEW.flow_id AND flow_type = 'elementary'
    ) THEN
        RAISE EXCEPTION
            'characterization_factors.flow_id % must reference an elementary flow',
            NEW.flow_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_check_cf_flow_is_elementary ON characterization_factors;
CREATE TRIGGER trg_check_cf_flow_is_elementary
    BEFORE INSERT OR UPDATE ON characterization_factors
    FOR EACH ROW
    EXECUTE FUNCTION trg_characterization_factor_flow_is_elementary();

COMMENT ON TABLE characterization_factors IS
    'Characterization factors: multiply an elementary exchange amount by the matching factor here to get its contribution to an impact category. One row per elementary flow per impact category. Real, cited factors only -- see file header for exactly what is and is not covered.';

COMMENT ON COLUMN characterization_factors.factor IS
    'Multiply one unit_id of the flow by this to get one unit of the impact category''s indicator.';

COMMENT ON COLUMN characterization_factors.is_placeholder IS
    'TRUE if this factor is a stand-in rather than a verified published value. Every row seeded in this project is FALSE; kept for future bulk-loaded factors that may need to stay flagged.';


/*
A fifth impact category, alongside the four in 03_seed_data.sql.

Accumulated Exceedance is a different model from CML acidification, with a different
indicator and a different unit (molc H+-eq, not kg SO2-eq). Storing
it under the existing 'AP' row would produce numbers that look comparable to CML results
and are not, so it gets its own row and the unit travels with the value.
*/
INSERT INTO impact_categories (name, code, method, unit, description)
VALUES (
    'Acidification (Accumulated Exceedance)',
    'AE',
    'ILCD 2011 (Seppala et al. 2006; Posch et al. 2008)',
    'molc H+-eq',
    'Acidification potential using the EU JRC-recommended Accumulated Exceedance method. Distinct from this project''s seed ''AP'' (CML 2002, kg SO2-eq) category -- different method, different unit, not directly comparable.'
)
ON CONFLICT (code, method) DO UPDATE
SET name = EXCLUDED.name,
    unit = EXCLUDED.unit,
    description = EXCLUDED.description;


/*
The factors themselves.

Looked up by name rather than a hardcoded id, so this file does not depend on
03_seed_data.sql's insertion order. Flow lookups filter on external_id IS NULL
because that is what distinguishes a seed flow from an ELCD one. ELCD ships several
rows named "Carbon dioxide, fossil" which would otherwise make the lookup amgiguous
once both datasets are loaded.

Note the fragility: the method string below is repeated in every lookup. A typo in
one of them makes its WHERE EXISTS return nothing, and the INSERT then succeeds having
written no row. A factor that quitely fails to appear is the faulure mode to watch for here.
*/
INSERT INTO characterization_factors (impact_category_id, flow_id, factor, unit_id, source, is_placeholder, notes)
SELECT
    (SELECT id FROM impact_categories WHERE code = 'GWP100' AND method = 'CML 2002'),
    (SELECT id FROM flows WHERE name = 'Carbon dioxide, fossil' AND external_id IS NULL),
    1.0,
    (SELECT id FROM units WHERE name = 'kg'),
    'Definitional: CO2 (fossil) is the GWP100 reference substance under IPCC 2007/AR-series methodology, and every GWP100 variant (IPCC, CML, ReCiPe) shares this definition.',
    FALSE,
    NULL
WHERE EXISTS (SELECT 1 FROM flows WHERE name = 'Carbon dioxide, fossil' AND external_id IS NULL)
  AND EXISTS (SELECT 1 FROM impact_categories WHERE code = 'GWP100' AND method = 'CML 2002')
ON CONFLICT (impact_category_id, flow_id) DO UPDATE
SET factor = EXCLUDED.factor, unit_id = EXCLUDED.unit_id, source = EXCLUDED.source, is_placeholder = EXCLUDED.is_placeholder;

INSERT INTO characterization_factors (impact_category_id, flow_id, factor, unit_id, source, is_placeholder, notes)
SELECT
    (SELECT id FROM impact_categories WHERE code = 'EP' AND method = 'CML 2002'),
    (SELECT id FROM flows WHERE name = 'Phosphate, to water' AND external_id IS NULL),
    1.0,
    (SELECT id FROM units WHERE name = 'kg'),
    'Definitional: this project''s EP category is expressed in kg PO4-equivalents; phosphate (PO4) is that indicator''s own reference substance.',
    FALSE,
    NULL
WHERE EXISTS (SELECT 1 FROM flows WHERE name = 'Phosphate, to water' AND external_id IS NULL)
  AND EXISTS (SELECT 1 FROM impact_categories WHERE code = 'EP' AND method = 'CML 2002')
ON CONFLICT (impact_category_id, flow_id) DO UPDATE
SET factor = EXCLUDED.factor, unit_id = EXCLUDED.unit_id, source = EXCLUDED.source, is_placeholder = EXCLUDED.is_placeholder;

INSERT INTO characterization_factors (impact_category_id, flow_id, factor, unit_id, source, is_placeholder, notes)
SELECT
    (SELECT id FROM impact_categories WHERE code = 'AE' AND method = 'ILCD 2011 (Seppala et al. 2006; Posch et al. 2008)'),
    (SELECT id FROM flows WHERE name = 'Ammonia' AND external_id IS NULL),
    3.02,
    (SELECT id FROM units WHERE name = 'kg'),
    'EC-JRC (2012), EUR 25167 EN, Table 3 (derived from Posch et al. 2008): NH3 = 3.02 molc H+-eq/kg.',
    FALSE,
    NULL
WHERE EXISTS (SELECT 1 FROM flows WHERE name = 'Ammonia' AND external_id IS NULL)
  AND EXISTS (SELECT 1 FROM impact_categories WHERE code = 'AE' AND method = 'ILCD 2011 (Seppala et al. 2006; Posch et al. 2008)')
ON CONFLICT (impact_category_id, flow_id) DO UPDATE
SET factor = EXCLUDED.factor, unit_id = EXCLUDED.unit_id, source = EXCLUDED.source, is_placeholder = EXCLUDED.is_placeholder;

INSERT INTO characterization_factors (impact_category_id, flow_id, factor, unit_id, source, is_placeholder, notes)
SELECT
    (SELECT id FROM impact_categories WHERE code = 'AE' AND method = 'ILCD 2011 (Seppala et al. 2006; Posch et al. 2008)'),
    (SELECT id FROM flows WHERE name = 'Nitrogen oxides' AND external_id IS NULL),
    0.74,
    (SELECT id FROM units WHERE name = 'kg'),
    'EC-JRC (2012), EUR 25167 EN, Table 3 (derived from Posch et al. 2008): NO2 = 0.74 molc H+-eq/kg, applied to the generic "nitrogen oxides" flow under the standard LCA "NOx as NO2" convention (the same convention the source applies to "sulphur oxides as SO2").',
    FALSE,
    'Mapping choice: the generic "Nitrogen oxides" elementary flow uses the NO2 factor, not a NOx-specific one -- ILCD/CML practice does not characterize a separate generic "NOx" factor.'
WHERE EXISTS (SELECT 1 FROM flows WHERE name = 'Nitrogen oxides' AND external_id IS NULL)
  AND EXISTS (SELECT 1 FROM impact_categories WHERE code = 'AE' AND method = 'ILCD 2011 (Seppala et al. 2006; Posch et al. 2008)')
ON CONFLICT (impact_category_id, flow_id) DO UPDATE
SET factor = EXCLUDED.factor, unit_id = EXCLUDED.unit_id, source = EXCLUDED.source, is_placeholder = EXCLUDED.is_placeholder, notes = EXCLUDED.notes;
