/*
- LCA Supply Chain Database
- File: 03_seed_data.sql
- Description: Minimal hand-crafted dataset for development and query testing.

Models a simplified wheat flour supply chain:
    wheat farming -> lorry transport -> flour milling -> [1 kg flour]

Values are illustrative only and are not real LCA data.
Run after 01_create_tables.sql and 02_constraints.sql.
*/


-- =============================================================================
-- GEOGRAPHIES
-- =============================================================================

INSERT INTO geographies (code, name, is_global) VALUES
    ('GLO', 'Global',   TRUE),
    ('RER', 'Europe',   FALSE),
    ('NO',  'Norway',   FALSE),
    ('FR',  'France',   FALSE),
    ('DE',  'Germany',  FALSE);


-- =============================================================================
-- UNITS
-- =============================================================================

INSERT INTO units (name, dimension) VALUES
    ('kg',  'mass'),
    ('t',   'mass'),
    ('kWh', 'energy'),
    ('MJ',  'energy'),
    ('m3',  'volume'),
    ('tkm', 'transport'),   -- tonne-kilometre, standard transport unit in LCA
    ('p',   'item'),        -- piece, for countable items
    ('m2',  'area');


-- =============================================================================
-- CATEGORIES
-- Top-level categories first, then sub-categories referencing their parents.
-- =============================================================================

INSERT INTO categories (name, parent_id, full_path) VALUES
    ('Agriculture',     NULL, 'Agriculture'),
    ('Transport',       NULL, 'Transport'),
    ('Food processing', NULL, 'Food processing'),
    ('Energy',          NULL, 'Energy');

-- Sub-categories (parent IDs: 1=Agriculture, 2=Transport, 3=Food processing, 4=Energy)
INSERT INTO categories (name, parent_id, full_path) VALUES
    ('Crop farming',    1, 'Agriculture/Crop farming'),
    ('Road transport',  2, 'Transport/Road transport'),
    ('Milling',         3, 'Food processing/Milling'),
    ('Electricity',     4, 'Energy/Electricity');


-- =============================================================================
-- IMPACT CATEGORIES
-- Using CML 2002 as the characterization method.
-- =============================================================================

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


-- =============================================================================
-- FLOWS
-- Product flows (internal technosphere exchanges) and
-- elementary flows (emissions and resources crossing the system boundary).
-- unit_id references: 1=kg, 2=t, 3=kWh, 4=MJ, 5=m3, 6=tkm
-- =============================================================================

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


-- =============================================================================
-- PROCESSES
-- category_id references: 5=Crop farming, 6=Road transport, 7=Milling
-- geography_id references: 2=RER (Europe)
-- =============================================================================

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


-- =============================================================================
-- EXCHANGES
-- Links processes to flows with amounts and directions.
-- process_id: 1=Wheat farming, 2=Transport, 3=Flour milling
-- flow_id references the flow IDs inserted above.
-- unit_id references: 1=kg, 3=kWh, 5=m3, 6=tkm
-- =============================================================================

-- PROCESS 1: Wheat farming (reference output: 1 kg wheat grain)
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

-- PROCESS 2: Lorry transport (reference output: 1 tkm)
INSERT INTO exchanges
    (process_id, flow_id, direction, amount, unit_id, is_reference_flow, comment)
VALUES
    (2, 5,  'output', 1.0,        6, TRUE,  'Reference flow: 1 tonne-kilometre (tkm)'),
    (2, 3,  'input',  0.000034,   1, FALSE, 'Diesel consumed per tkm (kg)'),
    (2, 6,  'output', 0.000095,   1, FALSE, 'CO2 from diesel combustion per tkm (kg)'),
    (2, 7,  'output', 0.00000062, 1, FALSE, 'NOx from combustion per tkm (kg)');

-- PROCESS 3: Flour milling (reference output: 1 kg wheat flour)
INSERT INTO exchanges
    (process_id, flow_id, direction, amount, unit_id, is_reference_flow, comment)
VALUES
    (3, 2,  'output', 1.0,        1, TRUE,  'Reference flow: 1 kg wheat flour'),
    (3, 1,  'input',  1.35,       1, FALSE, 'Wheat grain required per kg flour (milling yield ~74%)'),
    (3, 4,  'input',  0.088,      3, FALSE, 'Electricity for milling machinery (kWh)'),
    (3, 5,  'input',  0.27,       6, FALSE, 'Transport of wheat to mill (tkm)'),
    (3, 6,  'output', 0.0000095,  1, FALSE, 'CO2 from minor on-site combustion (kg)');


-- =============================================================================
-- IMPACT RESULTS
-- Illustrative LCIA scores per process per impact category.
-- impact_category_id: 1=GWP100, 2=AP, 3=EP, 4=CED
-- ON CONFLICT allows this block to be re-run safely.
-- =============================================================================

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