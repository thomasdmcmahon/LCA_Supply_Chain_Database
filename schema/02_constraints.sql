/*
- LCA Supply Chain Database
- File: 02_constraints.sql
- Description: Indexes, constraints, and integrity rules

-- Run after 01_create_tables.sql
*/

-- INDEXES

-- Processes
CREATE INDEX IF NOT EXISTS idx_processes_geography
    ON processes(geography_id);

CREATE INDEX IF NOT EXISTS idx_processes_category
    ON processes(category_id);

-- external_id already has a UNIQUE constraint in 01_create_tables.sql,
-- so PostgreSQL already creates an index for it.

-- Flows
CREATE INDEX IF NOT EXISTS idx_flows_flow_type
    ON flows(flow_type);

-- external_id already has a UNIQUE constraint in 01_create_tables.sql,
-- so PostgreSQL already creates an index for it.

-- Exchanges
CREATE INDEX IF NOT EXISTS idx_exchanges_process
    ON exchanges(process_id);

CREATE INDEX IF NOT EXISTS idx_exchanges_flow
    ON exchanges(flow_id);

CREATE INDEX IF NOT EXISTS idx_exchanges_direction
    ON exchanges(direction);

CREATE INDEX IF NOT EXISTS idx_exchanges_process_dir
    ON exchanges(process_id, direction);

-- Impact results
CREATE INDEX IF NOT EXISTS idx_impact_results_process
    ON impact_results(process_id);

CREATE INDEX IF NOT EXISTS idx_impact_results_category
    ON impact_results(impact_category_id);


/*
-- BUSINESS LOGIC CONSTRAINTS
*/

ALTER TABLE exchanges
    ADD CONSTRAINT chk_exchange_amount_nonzero
    CHECK (amount != 0);

ALTER TABLE processes
    ADD CONSTRAINT chk_reference_year_range
    CHECK (
        reference_year IS NULL
        OR reference_year BETWEEN 1990 AND 2100
    );

ALTER TABLE exchanges
    ADD CONSTRAINT chk_reference_flow_is_output
    CHECK (
        is_reference_flow = FALSE
        OR direction = 'output'
    );

CREATE UNIQUE INDEX IF NOT EXISTS idx_exchanges_one_reference_flow
    ON exchanges(process_id)
    WHERE is_reference_flow = TRUE;

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

CREATE UNIQUE INDEX IF NOT EXISTS idx_categories_unique_parent_name
    ON categories(parent_id, name)
    WHERE parent_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_categories_unique_root_name
    ON categories(name)
    WHERE parent_id IS NULL;

/* Optional: enable only if duplicate process-flow-direction exchanges should never exist in the source data.

ALTER TABLE exchanges
    ADD CONSTRAINT uq_exchanges_process_flow_direction
    UNIQUE (process_id, flow_id, direction);
*/

/*
-- COMMENTS
*/

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
