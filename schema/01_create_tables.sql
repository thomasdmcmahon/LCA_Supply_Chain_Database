/*
LCA Supply Chain Database, core tables

Run first before 02_constraints.sql. Docker compose excecutes everything in schema/ in filename order when the Postgres volume is empty.

The model is directed graph: processes are nodes, flows are what moves, exchanges are the edges. 
*/


/*
Enums: these value sets are ficed by the LCA model, not by the data, so the database should reject everything else.

flow_type matters for traversal. Product and waste flows stay inside the technosphere and connect processes to each otehr, so they can be followed upstream. Elementary flows cross into nature and are dead ends (they are what impact assessment is computed from).
*/
CREATE TYPE flow_type_enum AS ENUM('product', 'elementary', 'waste');

CREATE TYPE direction_enum AS ENUM('input', 'output');


/*
Where a process is located. Its own table so codes are not repeated as strings across thousands of rows, and so datasets can be filtered by region.

ELCD uses ISO country codes plus aggregates like RER (Europe) and GLO (global average).
*/
CREATE TABLE geographies (
    id SERIAL PRIMARY KEY,
    code VARCHAR(10) NOT NULL UNIQUE, -- 'NO', 'DE', 'RER', 'GLO', ...
    name VARCHAR(255) NOT NULL, -- 'Norway', 'Europe'
    is_global BOOLEAN NOT NULL DEFAULT FALSE
);


/*
Sector classification for processes, e.g. Agriculture > Crop production > wheat.

parent_id is self-referencing so the hierarchy can be any depth (source datasets do not agree on how many levels they use). full_path duplicates that information as a string; it is denormalized on purpoose, because displaying and filtering a path is far cheaper than walking the tree every time.
*/
CREATE TABLE categories (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    parent_id INT REFERENCES categories(id) ON DELETE SET NULL,
    full_path TEXT -- 'Agriculture/Crop production/Wheat'
);


/*
Proceeses: the nodes of the graph

One row is one activity that turns inputs into outputs
growing wheat, milling it, hauling it, generating the electricity to power the mill.
*/
CREATE TABLE processes (
    id SERIAL PRIMARY KEY,
    name VARCHAR(500) NOT NULL, 
    description TEXT,

    category_id INT REFERENCES categories(id) ON DELETE SET NULL,
    geography_id INT REFERENCES geographies(id) ON DELETE SET NULL,

    reference_year SMALLINT, -- Year the dataset describes

    /* Which dataset this row came from, so seed data and imported data
    can be told apart in queries: 'Seed data (illustrative)' or
    'ELCD 3.2 via openLCA ILCD export'*/
    source_dataset VARCHAR(255),

    /* The source dataset's own identifier (a UUID in ILCD).
    Unique so a re-run of the loader updates the existing row instead
    of duplicating it. NULL for hand-written seed data, which has no
    upstream source.
    */
    external_id VARCHAR(255) UNIQUE,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


/*
Units of measurement.

Note on 'dimension': it is a descriptive label only, inferred from
unit group names, and is NOT safe to use for deciding whether two
units can convert into each other. Two unrelated groups can end up
with the same label without sharing a reference point. Real convertability
is decideded by unit_group_external_id()
*/
CREATE TABLE units (
    id SERIAL PRIMARY KEY,
    name VARCHAR(50) NOT NULL UNIQUE, -- 'kg', 'MJ', 'm2', 'tkm'
    dimension VARCHAR(50) -- label only (see comment above)
);


/*
Flows: anything that moves. A product between two factories, an
emission into the air, a resoruce taken out of the ground, waste sent
to treatment ...

Flows are shared lookup rows, not owned by any one process. The same
'carbon dioxide, fossil' row is referneced by every process that emits it.
*/
CREATE TABLE flows (
    id SERIAL PRIMARY KEY,
    name VARCHAR(500) NOT NULL,
    description TEXT,
    flow_type flow_type_enum NOT NULL,

   /*The unit this flow is normally measured in. An individual
   exchange may use a different but compatible unit (see exchanges.unit_id).
   */
    unit_id INT REFERENCES units(id) ON DELETE SET NULL,

   /*
   CAS registry number, e.g. '124-38-9' cor carbon dioxide. This is the
   only reliable way to tell that two differnly-named or duplicated flow
   rows are the same substance (ELCD ships several entries fro fossil
   CO2, all sharing this same number). Not every flow has one:
   resource extraction and land use have no CAS
   */
    cas_number VARCHAR(20),


    external_id VARCHAR(255) UNIQUE, -- source dataset UUID
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


/*
Exchanges: the edges. One row says that one process consumes or produces
one flow, in one amount.

Every amount is expressed per one unit of the process's own reference flow.

That convention is what makes the supply chain computable: scaling an upstream process is just "amount I need" divided by "amount it produces".
*/
CREATE TABLE exchanges (
    id SERIAL PRIMARY KEY,

    /*
    CASCADE: an exchange has no meaning without its process. Delete the
     mill and the rows describing what the mill consumed should go too.
    */
    process_id INT NOT NULL REFERENCES processes(id) ON DELETE CASCADE,

    /*
    RESTRICT: flows are shared lookups. Deleting the CO2 row should
    not also delete every CO2 emission in the database.
    */
    flow_id INT NOT NULL REFERENCES flows(id) ON DELETE RESTRICT,

    direction direction_enum NOT NULL,

    /*
    NUMERIC(60, 50) because LCA inventories contain extremely small 
    values. ELCD has amount below 1e-28. The loader preserves this by carrying amounts as texts through the pipeline and convert to instance of Decimal never through float.
    */
    amount NUMERIC(60, 50) NOT NULL,

   /*
   Unit for this specific amount. Usually the flow's default, but source
   datasets sometimes express the same flow in a different compatible unit so it is recorded per exchange rathr than inherited.
   */
    unit_id INT REFERENCES units(id) ON DELETE SET NULL,

    -- 02_constraints.sql: at most one per process, and it must be an output.
    is_reference_flow BOOLEAN NOT NULL DEFAULT FALSE,


    comment TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


/*
Impact categories: the environmental questiosn the inventory can be 
scored against (climate change, acidiciation, eutrophication).

Note on method: the same emission scored under method CML 2 and under method Accumulated Exceedance gives different numbers in different units,
so a category is only meaningful together with the method it belongs to.
*/
CREATE TABLE impact_categories (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL, -- 'Climate change', ...
    code VARCHAR(50), --  'GWP100', 'AP', ...
    method VARCHAR(255), -- 'CML 2002', 'Accumulated Exceedance', ...
    unit VARCHAR(50) NOT NULL, --  'kg CO2-eq', 'molc H+ eq'
    description TEXT
);


/*
Impact results: what a process scores in a given category.
Derived, not source data. Each value is the sum over the process's
elementary flows of (exchange amount * characterization factor).
so 2 kg of methane at a GWP100 factor of 28 contibues 56 kg of CO2-eq.

Stored rather than computed on every query, which is also how msot LCA
databases distribute their results. Populated upsert_direct_impacts_for_all_processes().

Precision is lower than exchanges.amount because individual emissions
can be near 1e-17, gut an aggregated score is in the order of kilograms.
The trade-off is that a score below 1e-10 rounds to zero here.

*/
CREATE TABLE impact_results (
    id SERIAL PRIMARY KEY,
    process_id INT NOT NULL REFERENCES processes(id) ON DELETE CASCADE,
    impact_category_id INT NOT NULL REFERENCES impact_categories(id) ON DELETE CASCADE, 
    value NUMERIC(20, 10) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- One score per process per category. Recalculation updates in place.
    UNIQUE (process_id, impact_category_id) 
);
