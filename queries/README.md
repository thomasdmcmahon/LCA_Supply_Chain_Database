# Queries

Analytical SQL queries against the LCA supply chain database and seed data. Each file is standalone and well-commented. Run them in order for a progressive walkthrough of the schema, or jump to any file individually.

## How to run

From the project root, with the container running:

```bash
docker compose exec -T postgres psql -U lca_user -d lca_supply_chain < queries/<filename>.sql
```

## Files

### `01_basic_lookups.sql`

Single-table selects against every core table. Confirms data is present and readable. Good first check after initializing or reloadign the database.

### `02_exchanges_by_process.sql`

Joins exchanges to processes, flows, and units to produce a human readable bill of materials for each process. Shows all inputs and outputs with amounts and units. The core join patter that most other queries build on.

### `03_reference_flows.sql`

Identifies the reference flow for each process and verifies the one-per-process constraint holds. Includes a query that surfaces any process missing a reference flow entirely. Useful as a post-load validation check after ingesting real data.

### `04_elementary_flows.sql`

Filters exchanges to elementary flows only – the substances crossing the boundary between the industrial system and nature. Separates resource inputs (e.g. water abstraction) from emissions to air, water, and soil (e.g. CO2, ammonia, nitrate). Includes an aggregration across all processes by substance.

### `05_impact_results_ranked.sql`

Joins pre-calculated LCIA scores to impact categories and ranks processes within each category using a window function. Shows which process contributes most to each environmental metric (GWP100, AP, EP, CED) and surfaces the single worst process per category.

### `06_supply_chain_graph.sql`

"The centerpiece query". A recursive CTE that walks the product flow graph upstream from flour milling, resolving which processes supplies each product input. Follows by a cradle-to-gate inventory rollup that scales and sums all upstream elementary emissions back to 1 kg of wheat flour as the functional unit.
