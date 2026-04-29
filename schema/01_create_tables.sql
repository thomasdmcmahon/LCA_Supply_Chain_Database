/*
- LCA Supply Chain Database
- File: 01_create_tables.sql
- Description: Core table definitions for LCA inventory data 

-- Execution order: fun this file first, before 02_constraints.sql
*/

/*
--- ENUMERATIONS --- 
Defined as custom types to enforce valid values at the DB level.

Flow types map to three categories in ILCD/ecoinvent:
- product → goods/services exchanged between processes
- elementary → flows crossing the system boundary into/rom nature
- waste → outputs routed to waste treatment processes
*/
CREATE TYPE flow_type_enum AS ENUM ('product', 'elementary', 'waste');

-- Exchanges are either inputs to a process or outputs from a process
CREATE TYPE direction_enum AS ENUM ('input', 'output');

/*
--- GEOGRAPHY ---
Represents the location or region a process is associated with.
Kept as a separate table to avoid string duplication and enable filtering by continent, region, group, etc. in future.
*/
CREATE TABLE geographies (
    id SERIAL PRIMARY KEY,
    code VARCHAR(10) NOT NULL UNIQUE, -- e.g. 'NO', 'GLO', 'RER', 'DE'
    name VARCHAR(255) NOT NULL, -- e.g. 'Norway', 'Global', 'Europe'
    is_global BOOLEAN NOT NULL DEFAULT FALSE
);

/*
--- CATEGORIES ---
Hiearchical classification fo processes (e.g. 'Energy > Electricity > Wind')
Self-referencing parent_id allows arbitrary depth without a fixed hierarchy.
*/
CREATE TABLES categories (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    parent_id INT REFERENCES categories(id) ON DELETE SET NULL,
    full_path TEXT -- denormalzied for readability, e.g. 'Energy/Electricity/Wind'
);

/*
-- PROCESSES --
The central entity. Each row is one industrial or agricultural activity.
A process transforms inputs into outputs – it is the node in the LCA graph.
*/
CREATE TABLE processes (
    id SERIAL PRIMARY KEY,
    name VARCHAR(500) NOT NULL,
    description TEXT,
    category_id INT REFERENCES categories(id) ON DELETE SET NULL,
    geography_id INT REFERENCES geographies(id) ON DELETE SET NULL,
    reference_year SMALLINT, -- year the data represents
    source_dataset VARCHAR(255), -- 'e.g. 'Agribalyse 3.1'
    external_id VARCHAR(255) UNIQUE, -- original UUID from source dataset
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

/*
-- UNITS --
Physical units of measurement (kg, kWh, m3, MJ, etc.).
Separated from flows so unit conversions can be added later.
*/
CREATE TABLE units (
    id SERIAL PRIMARY KEY,
    name VARCHAR(50) NOT NULL UNIQUE, -- e.g. 'kg', 'kWh', 'm3' 'MJ'
    dimension VARCHAR(50) -- e.g. 'mass', 'energy', 'volume'
);

/*
-- FLOWS --
A flow is any substance, energy carrier, or service that moves between processes or between a process and the environment.

- flow_type determines where the flow sits in the model:
- product/waste → internal to the technosphere (between processes)
- elementary → crosses the system boundary (e.g. CO2 emitted to air)
- cas_nuber is the Chemical Abstracts Service registry number (useful for linking to external chemical databases.)
*/
CREATE TABLE flows(
    id SERIAL PRIMARY KEY,
    name VARCHAR(500) NOT NULL,
    description TEXT,
    flow_type flow_type_enum NOT NULL,
    unit_id INT REFERENCES units(id) ON DELETE SET NULL,
    cas_number VARCHAR(20) -- e.g. '124-38-9' for CO2
    external_id VARCHAR(255) UNIQUE -- original UUID from source dataset
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

/*
-- EXCHANGES --
The edges of the LCA graph. Each row links one process to one flow, with a direction (input/output) and an amount.

This is the most important table in this schema, it is where the physical relationships between processes are encoded.

is_reference_flow flags the one output that defines the functional unit of a process (e.g. '1 kg of milled wheat flour'). Every process has exactly one reference flow.
*/
CREATE TABLE exchanges (
    id SERIAL PRIMARY KEY,
    process_id INT NOT NULL REFERENCES processes(id) ON DELETE CASCADE,
    flow_id INT NOT NULL REFERENCES flows(id) ON DELETE RESTRICT,
    direction direction_enum NOT NULL,
    amount NUMERIC(20, 10) NOT NULL, -- high precision for small emission factors
    unit_id INT REFERENCES units(id) ON DELETE SET NULL,
    is_reference_flow BOOLEAN NOT NULL DEFAULT FALSE,
    comment TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

/*
-- IMPACT CATEGORIES --
Environemntal metrics used to aggregate elementary flows into scores.
Examples: GWP100 (climate change), AP (acidification), EP (eutrophication)

method is the characterization methodology (e.g. 'CML 2002', 'ReCiPe 2016').
Different methods produce different scores for the same inventory data.
*/
CREATE TABLE impact_categories (
    id          SERIAL          PRIMARY KEY,
    name        VARCHAR(255)    NOT NULL,           -- e.g. 'Climate change'
    code        VARCHAR(50),                        -- e.g. 'GWP100'
    method      VARCHAR(255),                       -- e.g. 'CML 2002'
    unit        VARCHAR(50)     NOT NULL,           -- e.g. 'kg CO2-eq','kg SO2-eq'
    description TEXT
);

/*
-- IMPACT RESULTS --
Pre-calculated environemntal impact scores per process.
These are derived values: sum of (exchange amount * characterization factor) for all elementary flows in a process, per impact category.

Storing them here avoids recalculating on every query and mirros how ecoinvent and Agribalyse distribute LCA results.
*/
CREATE TABLE impact_results (
    id SERIAL PRIMARY KEY,
    process_id INT NOT NULL REFERENCES processes(id) ON DELETE CASCADE,
    impact_category_id INT NOT NULL REFERENCES impact_categories(id) ON DELETE CASCADE,
    value NUMERIC(20, 10) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (process_id, impact_category_id) -- one score per process per category
);