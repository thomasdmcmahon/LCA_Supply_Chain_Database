# Schema

This folder contains the SQL files and ER diagram that define the database. Run them in order: `01_create_tables.sql`, `02_constraints.sql`, then `03_seed_data.sql` if you want some test data to play with. `04_characterization_factors.sql` through `07_supply_chain_rollup.sql` add the LCIA calculation engine, the unit conversion engine, and the generic supply-chain rollup on top of that — see below.

## How the database works

LCA is about tracking what goes into and out of industrial processes. A wheat farm takes in water, diesel, and sunlight, and puts out wheat grain. Along the way the farm emits CO2 and ammonia into the air. A flour mill takes in wheat grain and electricity, and puts out flour. Chain these processes together and you can ask questions like "what is the total carbon footprint of 1 kg of bread, all the way back to the farm?"

The database models this as a graph. **Processes** are the nodes. **Flows** are the things that move between them (wheat grain, CO2, water, electricity). **Exchanges** are the edges that connect a process to a flow and say how much of it goes in or out.

On top of that sits an impact layer. **Impact categories** are the environmental metrics we care about (climate change, acidification, etc.) and **impact results** store the pre-calculated scores for each process ("how much does this process contribute to each metric?").

## The tables, and why they connect the way they do

### `processes`

The central table. Each row is one industrial activity: wheat farming, transport, milling, whatever. Every other table either feeds into processes or hangs off them.

Connects to:

- `geographies` because where a process happens matters. Norwegian hydropower has a very different footprint to German coal power, even if it produces the same product (electricity).
- `categories` just for organisation. Makes it easier to filter processes by sector (agriculture, transport, energy, etc.).

### `geographies`

Simple lookup table. Stores location codes like `NO`, `GLO` (global), `RER` (Europe). Kept separate so the string "Europe" isn't duplicated across thousands of process rows.

### `categories`

Hierarchical classification for processes. A category can have a parent category, so you can build trees like `Energy > Electricity > Wind`. The `full_path` column stores the full path as a string (e.g. `"Energy/Electricity/Wind"`) so you don't have to walk the tree every time you want to display it.

Connects to itself via `parent_id`. That's the self-referencing foreign key that enables the hierarchy.

### `flows`

Anything that moves. Wheat grain, CO2, electricity, water are all flows. The `flow_type` column is the important one here:

- `product`: flows that stay inside the industrial system, moving between processes (wheat going from farm to mill).
- `elementary`: flows that cross the boundary between the industrial system and nature (CO2 emitted to air, water drawn from a river).
- `waste`: outputs that go to waste treatment.

This distinction matters because elementary flows are what you ultimately care about for environmental impact — they're the ones that actually hit the environment.

`flows` connects to `units` because every flow needs a unit of measurement (kg, kWh, m3, etc.).

### `units`

Small lookup table for units of measurement. Kept separate from flows for the same reason geographies are separate from processes — no point duplicating `'kg'` thousands of times.

### `exchanges`

The most important table. Each row is one connection between a process and a flow, with a direction (input or output) and an amount.

Worth knowing:

- `is_reference_flow` marks the one output that defines what the process produces. For the flour mill, that's 1 kg of flour. All other amounts in that process are relative to this reference.
- `amount` uses fixed-point precision (not floating point) because emission factors can be tiny numbers like `0.0000062`, and floating point arithmetic compounds rounding errors badly when you're summing thousands of exchanges.
- There's a constraint that ensures each process has **at most one** reference flow. That every process also has **at least one** is enforced during data loading, not at the database level.

Connects to both `processes` and `flows`. It's the join table that makes the graph work.

### `impact_categories`

Defines the environmental metrics. Things like GWP100 (global warming potential over 100 years, measured in kg CO2-equivalent), acidification potential, eutrophication potential, and so on. Each category belongs to a characterization method (e.g. CML 2002, ReCiPe) — different methods produce different scores for the same inventory data.

### `impact_results`

Stores one score per process per impact category. For example: "flour milling contributes 0.512 kg CO2-eq per kg flour under GWP100 (CML 2002)."

These scores can be hand-entered (the seed data does this) or derived from exchanges x characterization factors by the calculation engine below. Either way they're stored directly to avoid recalculating on every query. The unique constraint on `(process_id, impact_category_id)` ensures there's only ever one score per process per category.

Connects to both `processes` and `impact_categories`.

### `characterization_factors`

Added in `04_characterization_factors.sql`. One row per elementary flow per impact category: `factor` says how much one unit of that flow contributes to that category's indicator (e.g. 1 kg CO2 contributes 1 kg CO2-eq to GWP100). A trigger enforces `flow_id` must reference an elementary flow, since characterizing a product or waste flow doesn't mean anything.

This project only seeds a handful of real, cited factors for the flows in the seed wheat-flour data — see that file's header comment for exactly what's covered, what isn't, and where real factors for the rest of the ELCD-loaded flows should come from. `is_placeholder` exists to flag stand-in values if/when this table is bulk-loaded from a real CF database later; nothing seeded here uses it (everything seeded is a verified, cited number).

Connects to `impact_categories` and `flows`.

### LCIA calculation engine (`06_lcia_calculation.sql`)

Functions and procedures that derive `impact_results` from `exchanges x characterization_factors` instead of typing them by hand:

- `calculate_direct_impacts(process_id)` — read-only, one process's direct (gate-level) exchanges, grouped by impact category.
- `upsert_direct_impacts(process_id)` / `upsert_direct_impacts_for_all_processes()` — persist the above into `impact_results`. The latter is one set-based statement covering every process, safe to rerun (upsert semantics), and only writes categories it actually computed a value for — it never overwrites a hand-typed value for a category it has no factors for.
- `v_elementary_flows_without_cf` — a view listing elementary flows that are used in exchanges but have zero characterization factor coverage. Expected to list almost everything after a full ELCD load, since `characterization_factors` is seeded thin on purpose.

### Unit conversion engine (`05_unit_conversions.sql`)

Extends `units` with `unit_group_external_id` (the real conversion-compatibility key — NOT the free-text `dimension` column, see the file header for why), `to_base_unit_factor`, and `is_base_unit`. `convert_amount(amount, from_unit_id, to_unit_id)` converts between two units if they share a conversion group, and returns `NULL` (never raises) otherwise, so callers can filter/count unconvertible rows in ordinary set-based SQL. `v_exchange_unit_flags` applies this to every exchange against its flow's default unit and labels each one `matches_flow_default` / `convertible` / `incompatible` / `unit_missing`.

For ELCD-loaded units, real per-unit conversion factors already exist in the source XML (each ILCD unit group's `meanValue`) but aren't wired into the loader yet — see the follow-up note in this file for exactly what's needed in `load_to_postgres.py`.

### Supply-chain rollup (`07_supply_chain_rollup.sql`)

Generalizes the manual example in `queries/06_supply_chain_graph.sql` into parameterized functions:

- `supply_chain_scaled_processes(start_process_id, target_amount, max_depth)` — recursive upstream traversal with automatically computed scaling factors (no more hand-written `VALUES` lists), cycle-safe via a visited-process-id guard plus a depth cap.
- `supply_chain_inventory(...)` — aggregates elementary exchanges across the whole scaled chain into one row per flow, normalized to each flow's default unit via `convert_amount()`.
- `calculate_cradle_to_gate_impacts(...)` — runs that inventory through the same characterization logic as `calculate_direct_impacts()`, so a whole upstream supply chain can be scored in one call.
