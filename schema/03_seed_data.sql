/*
A small hand-written dataset: wheat farming, lorry transport, flour milling.
Three processes, small enough that every number in a query result can be checked
on paper.

    wheat farming -> lorry transport -> flour milling -> [1 kg flour]

Two things this is not. The exchange amounts are plausible but illustrative,
not sourced LCA data. And the impact_results at the bottom are placeholders
typed by hand. They were never derived from the exchanges above and the calculation
engine cannot reproduce them (see queries/09_lcia_calculation_validation.sql for why).

Run after 01_create_tables.sql and 02_constraints.sql. Not rerunnable: the unique
constraints on geographies.code and units.name will reject a second run. Use make reset.
*/


-- GEOGRAPHIES
INSERT INTO geographies (code, name, is_global) VALUES
    ('GLO', 'Global',   TRUE),
    ('RER', 'Europe',   FALSE),
    ('NO',  'Norway',   FALSE),
    ('FR',  'France',   FALSE),
    ('DE',  'Germany',  FALSE);


-- UNITS
-- Conversion groups and factors are added later, in 05_unit_conversions.sql
INSERT INTO units (name, dimension) VALUES
    ('kg',  'mass'),
    ('t',   'mass'),
    ('kWh', 'energy'),
    ('MJ',  'energy'),
    ('m3',  'volume'),
    ('tkm', 'transport'),   -- tonne-kilometre, standard transport unit in LCA
    ('p',   'item'),
    ('m2',  'area');


-- CATEGORIES
-- Roots first, then children referencing them by id.
--
-- The parent ids below assume SERIAL starts at 1, which holds on a fresh
-- volume. Same assumption applies to every hardcoded id in this file.
INSERT INTO categories (name, parent_id, full_path) VALUES
    ('Agriculture',     NULL, 'Agriculture'),
    ('Transport',       NULL, 'Transport'),
    ('Food processing', NULL, 'Food processing'),
    ('Energy',          NULL, 'Energy');

-- 1=Agriculture, 2=Transport, 3=Food processing, 4=Energy
INSERT INTO categories (name, parent_id, full_path) VALUES
    ('Crop farming',    1, 'Agriculture/Crop farming'),
    ('Road transport',  2, 'Transport/Road transport'),
    ('Milling',         3, 'Food processing/Milling'),
    ('Electricity',     4, 'Energy/Electricity');


-- IMPACT CATEGORIES
-- Mostly CML 2002. CED is its own method, and the two are not comparable, which
-- is why method is part of the identity (see uq_impact_categories_code_method).
--
-- 04_characterization_factors.sql adds a fifth, 'AE' under ILCD 2011, because
-- the only acidification factors that could be sourced use that method and a
-- different unit.
INSERT INTO impact_categories (name, code, method, unit, description) VALUES
    (
        'Climate change',
        'GWP100',
        'CML 2002',
        'kg CO2-eq',
        'Global warming potential over a 100-year time horizon.'
    ),
    (
        'Acidification',
        'AP',
        'CML 2002',
        'kg SO2-eq',
        'Acidification potential, measuring acid deposition to ecosystems.'
    ),
    (
        'Eutrophication',
        'EP',
        'CML 2002',
        'kg PO4-eq',
        'Eutrophication potential from nitrogen and phosphorus emissions to water.'
    ),
    (
        'Cumulative energy demand',
        'CED',
        'CED v1.09',
        'MJ',
        'Total primary energy demand across all sources.'
    );

-- FLOWS
-- unit_id: 1=kg, 2=t, 3=kWh, 4=MJ, 5=m3, 6=tkm
--
-- Seed flows get no external_id. That is what distinguishes them from
-- ELCD-loaded flows, and 04_characterization_factors.sql relies on it to
-- match the right "Carbon dioxide, fossil" row.
INSERT INTO flows (name, flow_type, unit_id, cas_number) VALUES
    -- Product flows
    ('Wheat grain, at farm',        'product',      1,  NULL),          -- id 1
    ('Wheat flour, at mill',        'product',      1,  NULL),          -- id 2
    ('Diesel',                      'product',      1,  '68334-30-5'),  -- id 3
    ('Electricity, low voltage',    'product',      3,  NULL),          -- id 4
    ('Transport, lorry >32t',       'product',      6,  NULL),          -- id 5

    -- Elementary flows
    ('Carbon dioxide, fossil',      'elementary',   1,  '124-38-9'),    -- id 6
    ('Nitrogen oxides',             'elementary',   1,  '11104-93-1'),  -- id 7
    ('Ammonia',                     'elementary',   1,  '7664-41-7'),   -- id 8
    ('Nitrate, to water',           'elementary',   1,  '14797-55-8'),  -- id 9
    ('Phosphate, to water',         'elementary',   1,  '14265-44-2'),  -- id 10
    ('Water, river',                'elementary',   5,  NULL);          -- id 11

-- PROCESSES
-- category_id: 5=Crop farming, 6=Road transport, 7=Milling
-- geography_id: 2=RER (Europe)
INSERT INTO processes
    (name, description, category_id, geography_id, reference_year, source_dataset)
VALUES
    (
        'Wheat farming, conventional, RER',
        'Production of 1 kg of wheat grain using conventional farming practices in Europe. '
        'Includes tillage, fertilizer application, pesticides, and harvest.',
        5, 2, 2020, 'Seed data (illustrative)'
    ),
    (
        'Transport, lorry >32t, RER',
        'Transport of goods by heavy lorry over European roads. '
        'Reference flow: 1 tonne-kilometre (tkm).',
        6, 2, 2020, 'Seed data (illustrative)'
    ),
    (
        'Flour milling, wheat, RER',
        'Milling of wheat grain into white wheat flour. '
        'Reference flow: 1 kg of wheat flour at the mill gate.',
        7, 2, 2020, 'Seed data (illustrative)'
    );

-- EXCHANGES
-- process_id: 1=Wheat farming, 2=Transport, 3=Flour milling
--
-- Every amount is per one unit of that process's reference flow.
--
-- Note where the chain ends: diesel and electricity are product inputs, but
-- no process here declares them as its reference output, so the traversal
-- stops at them. That boundary is deliberate (three processes are enough to
-- show the pattern)
--
-- PROCESS 1: Wheat farming, per 1 kg wheat grain
INSERT INTO exchanges
    (process_id, flow_id, direction, amount, unit_id, is_reference_flow, comment)
VALUES
    (1, 1,  'output', 1.0,        1, TRUE,  'Reference flow: 1 kg wheat grain'),
    (1, 3,  'input',  0.000052,   1, FALSE, 'Diesel for agricultural machinery (kg)'),
    (1, 4,  'input',  0.021,      3, FALSE, 'Electricity for irrigation pumping (kWh)'),
    (1, 11, 'input',  0.42,       5, FALSE, 'Water abstracted from river (m3)'),
    (1, 6,  'output', 0.00013,    1, FALSE, 'CO2 from diesel combustion (kg)'),
    (1, 8,  'output', 0.0028,     1, FALSE, 'Ammonia from fertilizer application (kg)'),
    (1, 9,  'output', 0.0019,     1, FALSE, 'Nitrate leaching to groundwater (kg)'),
    (1, 10, 'output', 0.00014,    1, FALSE, 'Phosphate runoff to water (kg)');

-- PROCESS 2: Lorry transport, per 1 tkm
INSERT INTO exchanges
    (process_id, flow_id, direction, amount, unit_id, is_reference_flow, comment)
VALUES
    (2, 5,  'output', 1.0,        6, TRUE,  'Reference flow: 1 tonne-kilometre (tkm)'),
    (2, 3,  'input',  0.000034,   1, FALSE, 'Diesel consumed per tkm (kg)'),
    (2, 6,  'output', 0.000095,   1, FALSE, 'CO2 from diesel combustion per tkm (kg)'),
    (2, 7,  'output', 0.00000062, 1, FALSE, 'NOx from combustion per tkm (kg)');

-- PROCESS 3: Flour milling, per 1 kg wheat flour
-- The two product inputs here are what the traversal resolves: 1.35 kg grain
-- to wheat farming, 0.27 tkm to lorry transport. Those are the scaling factors
-- supply_chain_processed() derives.
INSERT INTO exchanges
    (process_id, flow_id, direction, amount, unit_id, is_reference_flow, comment)
VALUES
    (3, 2,  'output', 1.0,        1, TRUE,  'Reference flow: 1 kg wheat flour'),
    (3, 1,  'input',  1.35,       1, FALSE, 'Wheat grain required per kg flour (milling yield ~74%)'),
    (3, 4,  'input',  0.088,      3, FALSE, 'Electricity for milling machinery (kWh)'),
    (3, 5,  'input',  0.27,       6, FALSE, 'Transport of wheat to mill (tkm)'),
    (3, 6,  'output', 0.0000095,  1, FALSE, 'CO2 from minor on-site combustion (kg)');

-- IMPACT RESULTS
-- impact_category_id: 1=GWP100, 2=AP, 3=EP, 4=CED
--
-- Placeholders, not derived values. They assume background emissions that are
-- not modelled as exchanges above (nitrous oxide from fertilizer breakdown, upstream
-- energy production) so no calulcation over the visible data could arrive at them.
--
-- Kept because they give the query files something to join against before the engine exists.
-- upsert_direct_impacts_for_all_processes() overwrites the ones it can compute (GWP100, EP)
-- and leaves AP and CED untouched, since no characterization factors cover those.
INSERT INTO impact_results
    (process_id, impact_category_id, value)
VALUES
    -- Wheat farming
    (1, 1, 0.350),
    (1, 2, 0.00280),
    (1, 3, 0.00210),
    (1, 4, 2.10),

    -- Lorry transport (per tkm)
    (2, 1, 0.000098),
    (2, 2, 0.00000071),
    (2, 3, 0.0),
    (2, 4, 0.00143),

    -- Flour milling (per kg flour)
    (3, 1, 0.512),
    (3, 2, 0.00341),
    (3, 3, 0.00224),
    (3, 4, 3.86)
ON CONFLICT (process_id, impact_category_id)
DO UPDATE SET value = EXCLUDED.value;
