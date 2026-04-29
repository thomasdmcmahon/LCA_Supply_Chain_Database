# Schema

This folder contains the SQL files and ER diagram that define the database. Run them in order: `01_create_tables.sql`, `02_constraints.sql`, then `03_seed_data.sql` if you want some test data to play with.

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

In a real pipeline these scores are calculated from exchanges multiplied by characterization factors. Here they're stored directly to avoid recalculating on every query. The unique constraint on `(process_id, impact_category_id)` ensures there's only ever one score per process per category.

Connects to both `processes` and `impact_categories`.

## Reading the ER diagram

The crow's foot notation on the relationship lines means:

- `||` — exactly one (mandatory)
- `o{` — zero or many (optional many)
- `||--o{` — "one process has zero or many exchanges" (a process with no exchanges would be empty, but the schema allows it).

The most important relationships to understand are:

- `processes ||--o{ exchanges` and `flows ||--o{ exchanges`: together these two relationships form the graph. An exchange can't exist without both a process and a flow.
- `categories ||--o{ categories`: the self-join that enables the hierarchy.
- `processes ||--o{ impact_results` and `impact_categories ||--o{ impact_results`: impact_results is the intersection table between processes and impact categories, storing the score for each combination.
