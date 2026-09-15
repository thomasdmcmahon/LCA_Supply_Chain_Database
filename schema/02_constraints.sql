/*
Indexes, constraints and table comments. Run after 01_create_tables.sql.

The constraints here are where the LCA rules live. Putting them in the
database rather than in the loader means they hold no matter what writes
to it, and it is the reason the traversal can assume a process has exactly
one reference flow without checking.

Note: the ALTER TABLE ... ADD CONSTRAINT statements are not idempotent and
will error on a second run. That is fine as long as this file only runs against
the empty volume (see make reset), which is how Docker executes it.
*/

-- INDEXES

-- Foreign keys are not indexed automatically in Postgres.
CREATE INDEX IF NOT EXISTS idx_processes_geography
    ON processes(geography_id);

CREATE INDEX IF NOT EXISTS idx_processes_category
    ON processes(category_id);


-- flow_type is the filter in almost every analysis query: product flows for
-- traversal, elementary flows for impacts.
CREATE INDEX IF NOT EXISTS idx_flows_flow_type
    ON flows(flow_type);

-- 212k rows, and the recursive traversal joins on process_id at every step.
CREATE INDEX IF NOT EXISTS idx_exchanges_process
    ON exchanges(process_id);

CREATE INDEX IF NOT EXISTS idx_exchanges_flow
    ON exchanges(flow_id);

CREATE INDEX IF NOT EXISTS idx_exchanges_direction
    ON exchanges(direction);

-- The composite covers "product inputs of this process", which is the hot
-- path in supply_chain_scaled_processes().
CREATE INDEX IF NOT EXISTS idx_exchanges_process_dir
    ON exchanges(process_id, direction);

CREATE INDEX IF NOT EXISTS idx_impact_results_process
    ON impact_results(process_id);

CREATE INDEX IF NOT EXISTS idx_impact_results_category
    ON impact_results(impact_category_id);

-- Not indexed here: processes.external_id and flows.external_id already have
-- UNIQUE constraints from 01_create_tables.sql, and Postgres backs those
-- with an idex

-- CONSTRAINTS

-- A zero-amount exchange is an edge that carries nothing. Negative amounts
-- are allowed (ELCD uses them for waste leaving the system).

ALTER TABLE exchanges
    ADD CONSTRAINT chk_exchange_amount_nonzero
    CHECK (amount != 0);

-- A type catcher, not a data quality rule. The upper bound is deliberately
-- loose: LCA datasets can describe projected scenarios.
ALTER TABLE processes
    ADD CONSTRAINT chk_reference_year_range
    CHECK (
        reference_year IS NULL
        OR reference_year BETWEEN 1990 AND 2100
    );

-- The reference flow is what the process produces, so it cannot be an input.
ALTER TABLE exchanges
    ADD CONSTRAINT chk_reference_flow_is_output
    CHECK (
        is_reference_flow = FALSE
        OR direction = 'output'
    );

/*
At most one reference flow per process. Two would make "per one unit of
the reference flow" ambiguous and break every scaling calcualation downstream.

A partial unique index rather than a UNIQUE constraint: the uniqueness only
applies to rows where is_reference_flow is TRUE. A plain unique index on
process_id would allow only one exchange per process entirely.

Note this enforces at most one, not at least one. Nothing here can require a
process to have a reference flow (that is checked after loading, in
queries/03_reference_flows.sql and 07_elcd.validation.sql)
*/
CREATE UNIQUE INDEX IF NOT EXISTS idx_exchanges_one_reference_flow
    ON exchanges(process_id)
    WHERE is_reference_flow = TRUE;


/*
An impact category is identified by code plus method, not code alone:
acidification under CML 2002 (kg S02-eq) under ILCD 2011 (molc H+-eq)
are different indicators in different units, and must never be summer or
compared.

Wrapped in a DO block because ALTER TABLE ... ADD CONSTRAINT has no
IF NOT EXISTS form.
*/
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'uq_impact_categories_code_method'
    ) THEN
        ALTER TABLE impact_categories
            ADD CONSTRAINT uq_impact_categories_code_method
            UNIQUE (code, method);
    END IF;
END $$;

/*
Category names are not unique within their parent, and separately unique
among root categories. Two indexes rather than one because NULL never equals NULL
in Postgres. A plain UNIQUE (parent_id, name) would let any number of identically
named root categories through.
*/
CREATE UNIQUE INDEX IF NOT EXISTS idx_categories_unique_parent_name
    ON categories(parent_id, name)
    WHERE parent_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_categories_unique_root_name
    ON categories(name)
    WHERE parent_id IS NULL;

/*
Left off deliberately: ELCD records the same flow more than once in the same
process and direction (867 such combinations in the current load, e.g. barite
appearing twice in process 5 at 2.3e-15 and 2.4e-4 kg). These are separate entries,
not duplicates, so aggregation sums them rather than picking one. Enforcing uniqueness
here would reject valid source data.

ALTER TABLE exchanges
    ADD CONSTRAINT uq_exchanges_process_flow_direction
    UNIQUE (process_id, flow_id, direction);
*/

-- TABLE AND COLUMN COMMENTS
-- Visible from psql (\d+) without opening this file

COMMENT ON TABLE processes IS
    'Industrial or agricultural activities. The nodes of the LCA supply chain graph.';

COMMENT ON TABLE flows IS
    'Substances, energy carriers, or services that move between processes or between a process and nature.';

COMMENT ON TABLE exchanges IS
    'Directed connections between processes and flows. The edges of the LCA graph. direction=input means the process consumes this flow; direction=output means it produces it.';

COMMENT ON TABLE impact_categories IS
    'Environmental metrics, e.g. GWP100 or AP, under a characterization method, e.g. CML 2002.';

COMMENT ON TABLE impact_results IS
    'Pre-aggregated LCIA scores per process per impact category. Derived from exchanges multiplied by characterization factors.';

COMMENT ON COLUMN exchanges.is_reference_flow IS
    'TRUE for the output flow that defines the functional unit of this process. The database enforces at most one reference flow per process; validation should confirm that each process has at least one.';

COMMENT ON COLUMN exchanges.amount IS
    'Quantity of the flow per one unit of the process reference flow. Stored with high precision to preserve small emission factors.';

COMMENT ON COLUMN flows.cas_number IS
    'Chemical Abstracts Service registry number. Enables linking to external chemical databases.';
