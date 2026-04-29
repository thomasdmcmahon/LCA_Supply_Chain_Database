/*
- LCA Supply Chain Database
- File: 01_create_tables.sql
- Description: Core table definitions for LCA inventory data

-- Execution order: run this file first, before 02_constraints.sql
*/

/*
--- ENUMERATIONS ---
Defined as custom PostgreSQL enum types to enforce valid values at the database level.

flow_type_enum:
- product: goods or services exchanged between processes
- elementary: flows crossing the system boundary between the technosphere and nature
- waste: outputs routed to waste treatment processes

direction_enum:
- input: the process consumes this flow
- output: the process produces this flow
*/

CREATE TYPE flow_type_enum AS ENUM ('product', 'elementary', 'waste');

CREATE TYPE direction_enum AS ENUM ('input', 'output');


/*
--- GEOGRAPHIES ---
Represents the location or region associated with a process.

Examples:
- NO: Norway
- GLO: Global
- RER: Europe

Kept as a separate table to avoid repeated geography strings and to make
future filtering by country, region, or global dataset easier.
*/

CREATE TABLE geographies (
    id SERIAL PRIMARY KEY,

    -- Short geography code, e.g. 'NO', 'GLO', 'RER', 'DE'
    code VARCHAR(10) NOT NULL UNIQUE,

    -- Human-readable geography name, e.g. 'Norway', 'Global', 'Europe'
    name VARCHAR(255) NOT NULL,

    -- TRUE when the geography represents a global average dataset
    is_global BOOLEAN NOT NULL DEFAULT FALSE
);


/*
--- CATEGORIES ---
Hierarchical classification for processes.

Examples:
- Agriculture > Crop production > Wheat
- Transport > Road freight
- Food processing > Milling

The self-referencing parent_id allows arbitrary category depth without
hard-coding a fixed hierarchy.
*/

CREATE TABLE categories (
    id SERIAL PRIMARY KEY,

    -- Category name at this hierarchy level
    name VARCHAR(255) NOT NULL,

    -- Optional parent category for nested category trees
    parent_id INT REFERENCES categories(id) ON DELETE SET NULL,

    -- Denormalized full path for easier display and filtering,
    -- e.g. 'Agriculture/Crop production/Wheat'
    full_path TEXT
);


/*
--- PROCESSES ---
The central entity in the database.

Each row represents one industrial, agricultural, transport, or service activity.
In the LCA supply chain graph, processes are the nodes.

A process transforms input flows into output flows.
*/

CREATE TABLE processes (
    id SERIAL PRIMARY KEY,

    -- Process name, e.g. 'wheat grain production, conventional'
    name VARCHAR(500) NOT NULL,

    -- Optional longer process description or metadata summary
    description TEXT,

    -- Optional classification category
    category_id INT REFERENCES categories(id) ON DELETE SET NULL,

    -- Optional process geography
    geography_id INT REFERENCES geographies(id) ON DELETE SET NULL,

    -- Year the dataset represents, e.g. 2020
    reference_year SMALLINT,

    -- Source database or dataset name, e.g. 'Agribalyse 3.1'
    source_dataset VARCHAR(255),

    -- Original process identifier from the source dataset,
    -- e.g. an OpenLCA, Agribalyse, or ecoinvent UUID
    external_id VARCHAR(255) UNIQUE,

    -- Timestamp for when this row was loaded into the local database
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


/*
--- UNITS ---
Physical units of measurement.

Examples:
- kg
- kWh
- m3
- MJ
- tkm

Separated from flows so unit metadata and future unit conversion logic
can be managed centrally.
*/

CREATE TABLE units (
    id SERIAL PRIMARY KEY,

    -- Unit symbol or name, e.g. 'kg', 'kWh', 'm3', 'MJ'
    name VARCHAR(50) NOT NULL UNIQUE,

    -- Physical dimension, e.g. 'mass', 'energy', 'volume', 'transport'
    dimension VARCHAR(50)
);


/*
--- FLOWS ---
A flow is any substance, energy carrier, product, waste, or service that moves
between processes or between a process and the environment.

Flow types:
- product/waste flows belong to the technosphere and connect processes
- elementary flows cross the system boundary, e.g. emissions to air or water

In the LCA graph, flows label the physical exchanges connected to processes.
*/

CREATE TABLE flows (
    id SERIAL PRIMARY KEY,

    -- Flow name, e.g. 'carbon dioxide, fossil' or 'wheat grain'
    name VARCHAR(500) NOT NULL,

    -- Optional longer description of the flow
    description TEXT,

    -- Flow category enforced by enum:
    -- 'product', 'elementary', or 'waste'
    flow_type flow_type_enum NOT NULL,

    -- Default unit for this flow
    unit_id INT REFERENCES units(id) ON DELETE SET NULL,

    -- Chemical Abstracts Service registry number,
    -- useful for linking chemical flows to external databases
    -- Example: '124-38-9' for carbon dioxide
    cas_number VARCHAR(20),

    -- Original flow identifier from the source dataset
    external_id VARCHAR(255) UNIQUE,

    -- Timestamp for when this row was loaded into the local database
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


/*
--- EXCHANGES ---
The edges of the LCA inventory graph.

Each exchange links:
- one process
- one flow
- one direction
- one amount

Examples:
- A wheat farming process outputs 1 kg wheat grain
- A flour milling process inputs 1.2 kg wheat grain
- A process outputs 0.1 kg CO2 to air

is_reference_flow marks the output flow that defines the functional unit
of a process, e.g. '1 kg flour'. Domain constraints for reference flows
are added in 02_constraints.sql.
*/

CREATE TABLE exchanges (
    id SERIAL PRIMARY KEY,

    -- Process that consumes or produces the flow
    process_id INT NOT NULL REFERENCES processes(id) ON DELETE CASCADE,

    -- Flow being consumed or produced
    flow_id INT NOT NULL REFERENCES flows(id) ON DELETE RESTRICT,

    -- Whether this flow is an input to or output from the process
    direction direction_enum NOT NULL,

    -- Quantity of the flow per one unit of the process reference flow.
    -- NUMERIC is used for precision because LCA data often contains very
    -- small emission factors.
    amount NUMERIC(20, 10) NOT NULL,

    -- Unit used for this exchange amount.
    -- Usually matches the flow's default unit, but is kept here because
    -- source datasets may express exchanges in different compatible units.
    unit_id INT REFERENCES units(id) ON DELETE SET NULL,

    -- TRUE for the output flow that defines the functional unit of the process
    is_reference_flow BOOLEAN NOT NULL DEFAULT FALSE,

    -- Optional notes from the source dataset or loader
    comment TEXT,

    -- Timestamp for when this row was loaded into the local database
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


/*
--- IMPACT CATEGORIES ---
Environmental impact metrics used in Life Cycle Impact Assessment, LCIA.

Examples:
- GWP100: global warming potential over 100 years
- AP: acidification potential
- EP: eutrophication potential
- CED: cumulative energy demand

The method column stores the characterization method, e.g. 'CML 2002'
or 'ReCiPe 2016'. Different methods can produce different scores for
the same inventory data.
*/

CREATE TABLE impact_categories (
    id SERIAL PRIMARY KEY,

    -- Human-readable impact category name, e.g. 'Climate change'
    name VARCHAR(255) NOT NULL,

    -- Short code, e.g. 'GWP100', 'AP', 'EP', 'CED'
    code VARCHAR(50),

    -- Characterization method, e.g. 'CML 2002' or 'ReCiPe 2016'
    method VARCHAR(255),

    -- Unit of the impact score, e.g. 'kg CO2-eq', 'kg SO2-eq'
    unit VARCHAR(50) NOT NULL,

    -- Optional explanation of the impact category
    description TEXT
);


/*
--- IMPACT RESULTS ---
Pre-calculated environmental impact scores per process and impact category.

These are derived values, normally calculated as:

    exchange amount × characterization factor

summed over relevant elementary flows for each process and impact category.

Storing impact results avoids recalculating LCIA scores on every query and
matches how many LCA databases distribute pre-aggregated impact results.
*/

CREATE TABLE impact_results (
    id SERIAL PRIMARY KEY,

    -- Process being scored
    process_id INT NOT NULL REFERENCES processes(id) ON DELETE CASCADE,

    -- Impact category being measured
    impact_category_id INT NOT NULL REFERENCES impact_categories(id) ON DELETE CASCADE,

    -- LCIA score value for this process and impact category
    value NUMERIC(20, 10) NOT NULL,

    -- Timestamp for when this result was loaded or calculated
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Ensures one score per process per impact category
    UNIQUE (process_id, impact_category_id)
);