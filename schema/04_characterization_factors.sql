/*
- LCA Supply Chain Database
- File: 04_characterization_factors.sql
- Description: Characterization factors linking elementary flows to impact
  categories, plus a small, real, cited set of factors for the seed
  wheat-flour dataset.

Run after 01_create_tables.sql, 02_constraints.sql, and 03_seed_data.sql.

WHAT THIS FILE DOES NOT DO
Characterization factors are sourced numbers, not invented ones. This file
seeds only the handful this project could verify against a primary source
during development -- it is nowhere near a full CF database. Specifically:

  - Coverage is limited to the elementary flows present in the illustrative
    wheat-flour seed data (03_seed_data.sql): CO2, ammonia, nitrogen oxides,
    and phosphate. Nitrate (eutrophication) and "Water, river" (a resource
    flow with no matching impact category in this project) are deliberately
    left uncharacterized -- no verified primary-source factor was located for
    nitrate during this session, and it would be worse to guess than to leave
    it visibly blank. See `v_elementary_flows_without_cf`
    (06_lcia_calculation.sql) to see what's missing at query time.
  - "Cumulative energy demand" (impact_categories.code = 'CED') gets no
    factors here at all. CED is characterized on *resource extraction* flows
    (e.g. "Crude oil, in ground", "Hard coal, in ground", each with a
    calorific-value-based factor), not on the emissions/elementary flows this
    seed dataset models. None of those resource flows exist in the seed data,
    so there is nothing correct to characterize yet.
  - None of this touches the real ELCD 3.2 load (65k flows, mostly with no
    CF at all). Bulk-sourcing real factors for that dataset -- e.g. from the
    ILCD 2011 Recommended LCIA methods CF database (JRC, see source below) or
    a licensed method like ecoinvent's own LCIA implementation -- is future
    work; this file only proves the calculation engine (06_lcia_calculation.sql)
    is correct end-to-end on a small, checkable example.

SOURCES USED (real, cited, not invented)
  - GWP100, CO2 (fossil) = 1 kg CO2-eq/kg. Definitional: CO2 is the reference
    substance for every GWP100 variant (IPCC, CML, ReCiPe alike), so this
    value is not method-specific.
  - Eutrophication, Phosphate = 1 kg PO4-eq/kg. Definitional: this project's
    seed 'EP' category is expressed in kg PO4-equivalents and phosphate (PO4)
    is that indicator's own reference substance, independent of which
    eutrophication submodel (CML, ReCiPe rescaled to PO4-eq, etc.) is behind
    it.
  - Acidification, Ammonia = 3.02 molc H+-eq/kg; Nitrogen oxides = 0.74 molc
    H+-eq/kg (mapped from the standard "NOx as NO2" LCA convention, the same
    convention used for "sulphur oxides as SO2" in the same source).
    These are NOT CML 2002 kg-SO2-eq factors (a search for verifiable CML
    2002 acidification numbers during this session produced inconsistent
    secondary-source values for ammonia -- 1.6 vs 1.88 kg SO2-eq/kg
    depending on source -- so none of those were used here). Instead these
    use the EU JRC's own recommended Accumulated Exceedance method, which
    ships a fully derived, citable table:
      European Commission, Joint Research Centre, Institute for Environment
      and Sustainability (2012). "Characterisation factors of the ILCD
      Recommended Life Cycle Impact Assessment methods -- Database and
      Supporting Information," 1st edition, EUR 25167 EN, section 3.6,
      Table 3 (derived from Posch et al., 2008), doi:10.2788/60825.
      https://eplca.jrc.ec.europa.eu/uploads/LCIA-characterization-factors-of-the-ILCD.pdf
    Because the unit (molc H+-eq) differs from the seed 'AP' category's
    kg SO2-eq, these factors are attached to a new impact_categories row
    ('AE' / ILCD 2011) rather than forced into the existing CML 'AP' row --
    see below. The original seed 'AP' (CML 2002) category is left with no
    factors rather than mixing methods under a label that wouldn't match.
*/

CREATE TABLE IF NOT EXISTS characterization_factors (
    id SERIAL PRIMARY KEY,

    -- Impact category this factor contributes to. The characterization
    -- *method* is implied by the category (impact_categories.method), so
    -- there is one factor per (impact_category, flow) pair -- not per
    -- method name -- matching the impact_categories table's own
    -- (code, method) uniqueness.
    impact_category_id INT NOT NULL REFERENCES impact_categories(id) ON DELETE CASCADE,

    -- Elementary flow being characterized. In principle this should only
    -- ever reference flows.flow_type = 'elementary'; enforced by a trigger
    -- below rather than a CHECK, since CHECK constraints can't reference
    -- other tables.
    flow_id INT NOT NULL REFERENCES flows(id) ON DELETE CASCADE,

    -- Multiply one unit_id of this flow by this factor to get one unit of
    -- the impact category's indicator (e.g. kg CO2-eq per kg CO2).
    -- NUMERIC(60, 50) matches exchanges.amount so a factor sourced at
    -- LCA-scale precision isn't truncated here either.
    factor NUMERIC(60, 50) NOT NULL,

    -- The unit this factor is expressed per. Usually the flow's own default
    -- unit. Kept explicit (rather than assumed) because a factor sourced
    -- from the literature may be published per a different unit than this
    -- database's flow default -- the calculation engine converts between
    -- them via convert_amount() (05_unit_conversions.sql).
    unit_id INT REFERENCES units(id) ON DELETE SET NULL,

    -- Citation for where this number came from. Required in spirit, not
    -- enforced by NOT NULL, so a row can never be mistaken for something
    -- verified when it wasn't.
    source TEXT,

    -- TRUE marks a factor that is a stand-in (e.g. a rough order-of-magnitude
    -- guess) rather than a verified published value. Every factor seeded by
    -- this file is FALSE -- see header comment. Kept for future bulk-loading
    -- work where placeholders may be unavoidable and must stay visibly
    -- flagged rather than silently trusted.
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

-- Enforce flow_id -> elementary at the database level. A CHECK constraint
-- can't reference another table, so this needs a trigger.
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
--- NEW IMPACT CATEGORY: Acidification (Accumulated Exceedance, ILCD 2011) ---
Added alongside the existing seed 'AP' (CML 2002, kg SO2-eq) category rather
than reusing it, because the only acidification factors this project could
verify (JRC 2012, Table 3) use a different method and a different unit
(molc H+-eq, not kg SO2-eq). The original 'AP' row is untouched and still has
no characterization_factors rows -- see file header.
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
--- CHARACTERIZATION FACTORS ---
Looked up by flow name / impact category code rather than hardcoded IDs, so
this file doesn't depend on insertion order staying exactly as it is in
03_seed_data.sql. Flow lookups also filter external_id IS NULL: seed flows
never get an external_id (only ELCD-loaded flows do), and the real ELCD
export can plausibly contain a same-named flow (e.g. another "Carbon
dioxide, fossil"), which would otherwise make "WHERE name = ..." ambiguous
if this file is ever (re)run against a database that already has both seed
and ELCD data loaded.
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
