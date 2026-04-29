/*
- LCA Supply Chain Database
- File: 02_constraints.sql
- Description: Indexes, constraints, and integrity rules

-- Run after 01_create_tables.sql
*/

/*
-- INDEXES --
Added on columns that appear frequently in WHERE claues and JOINs.
The most query-critical paths are:
- exchanges → process_id (all supply chain traversal queries)
- exchanges → flow_id (all emission lookups)
- flows → flow_type (filtering elementary vs product flows)
- impact_results → process_id (all impact scoring queries)
*/

-- Processes
CREATE INDEX idx_processes_geography ON processes(geography_id);
CREATE INDEX idx_processes_category ON processes(category_id);
CREATE INDEX idx_processes_external_id ON processes(external_id);

-- Flows
CREATE INDEX idx_flows_flow_type ON flows(flow_type);
CREATE INDEX idx_flows_external_id ON flows(external_id);

-- Exchanges - the most queried table
CREATE INDEX idx_exchanges_process ON exchanges(process_id);
CREATE INDEX idx_exchanges_flow ON exchanges(flow_id);
CREATE INDEX idx_exchanges_direction ON exchanges(direction);
-- Composite index for the most common join pattern: all inputs/outputs of a process
CREATE INDEX idx_exchanges_process_dir ON exchanges(process_id, direction);

/*
-- BUSINESS LOGIC CONSTRAINTS --
Rules that enforce domain-specific correctness beyond basic types.

1. Exchange amounts should not be zero - a zero exchange carries no meaning and typically indicates a data loading error. Negative values are valid for avoided products (a modeling concept in LCA, e.g. avoided waste).
*/
ALTER TABLE exchanges
    ADD CONSTRAINT chk_exchange_amount_nonzero
    CHECK (amount != 0);

/*
2. Impact results values can be negative (some impact categories allow credits, e.g. carbon sequestration in GWP), but NULL is not meaningful. The NOT NULL on the column handles this already.

3. Reference year should be a plausible range for LCA data
*/
ALTER TABLE processes
    ADD CONSTRAINT chk_reference_year_range
    CHECK (reference_year IS NULL OR reference_year BETWEEN 1990 AND 2100);

/*
4. A process should have at most one reference flow.
This enforces via a partial unique index: unique on process_id
only where is_reference_flow = TRUE.
*/
CREATE UNIQUE INDEX idx_exchanges_one_reference_flow
    ON exchanges(process_id)
    WHERE is_reference_flow = TRUE;

/*
-- COMMENTS --
Stored in the database catalog – visible in psql \d+ and most GUI tools.
Serves as inline documentation for anyone reading the schema directly.
*/
COMMENT ON TABLE processes IS
    'Industrial or agricultural activities. The nodes of the LCA supply chain graph.';
 
COMMENT ON TABLE flows IS
    'Substances, energy carriers, or services that move between processes or between a process and nature.';
 
COMMENT ON TABLE exchanges IS
    'Directed connections between processes and flows. The edges of the LCA graph. '
    'direction=input means the process consumes this flow; direction=output means it produces it.';
 
COMMENT ON TABLE impact_categories IS
    'Environmental metrics (e.g. GWP100, AP) under a characterization method (e.g. CML 2002).';
 
COMMENT ON TABLE impact_results IS
    'Pre-aggregated LCIA scores per process per impact category. '
    'Derived from exchanges × characterization factors.';
 
COMMENT ON COLUMN exchanges.is_reference_flow IS
    'TRUE for the single output flow that defines the functional unit of this process. '
    'Every process has exactly one reference flow.';
 
COMMENT ON COLUMN exchanges.amount IS
    'Quantity of the flow per one unit of the process reference flow. '
    'Stored with high precision (10 decimal places) to preserve small emission factors.';
 
COMMENT ON COLUMN flows.cas_number IS
    'Chemical Abstracts Service registry number. Enables linking to external chemical databases.';