````markdown
# Project Overview

The **LCA Supply Chain Database** is a PostgreSQL-based data system for modelling product life cycles using Life Cycle Assessment data. It represents industrial supply chains as a graph of processes, flows, and exchanges, then layers environmental impact results on top so users can query how materials, emissions, resources, and impacts move through a product system.

The project currently supports local seed data and an ELCD 3.2 ingestion pipeline using an openLCA ILCD export.

## 1. Problem Statement

Life Cycle Assessment data is complex because it describes not just individual products, but entire chains of industrial activity.

A single product, such as wheat flour, depends on many upstream processes:

```mermaid
flowchart LR
    Farm["Wheat farming"] -->|wheat grain| Mill["Flour milling"]
    Transport["Lorry transport"] -->|transport service| Mill
    Mill -->|wheat flour| Product["Final product"]
```

Each process consumes inputs, produces outputs, and may emit substances to air, water, or soil. Traditional flat files or ad hoc spreadsheets make it difficult to answer questions like:

- What are all the inputs and outputs for a process?
- Which upstream processes supply a product input?
- Which emissions cross the boundary between industry and nature?
- What is the cradle-to-gate inventory for a product?
- Which processes contribute most to climate change, acidification, or energy demand?
- Can real external LCA datasets be loaded into a queryable relational model?

The central problem is that LCA data is both **relational** and **graph-like**. Processes connect to flows, flows connect processes to other processes, and elementary flows connect the industrial system to the environment. The project solves this by giving that structure a clean database model and a repeatable data pipeline.

## 2. How The Project Solves the Problem

The project models a life cycle inventory as a graph inside PostgreSQL.

```mermaid
flowchart TD
    P["processes<br/>industrial activities"] --> E["exchanges<br/>amount + direction"]
    F["flows<br/>products, emissions, resources"] --> E
    U["units<br/>kg, kWh, MJ, m3"] --> F
    U --> E
    G["geographies<br/>GLO, RER, DE, etc."] --> P
    C["categories<br/>sector hierarchy"] --> P
    IC["impact_categories<br/>GWP100, AP, EP, CED"] --> IR["impact_results"]
    P --> IR
```

The key idea is:

- **Processes are nodes**: farming, transport, milling, electricity generation, chemical production.
- **Flows are things that move**: wheat grain, electricity, CO2, ammonia, water, waste.
- **Exchanges are edges**: a process consumes or produces a flow in a specific amount.
- **Reference flows define the functional unit**: for example, "1 kg wheat flour" is the main output that other amounts are relative to.
- **Impact results store environmental scores**: pre-calculated LCIA values per process and impact category.

This structure allows both ordinary SQL joins and graph-style recursive queries. For example, a query can start at flour milling, find all product inputs, resolve which upstream process supplies each product, and recursively walk the supply chain.

```mermaid
flowchart BT
    CO2["CO2 emission<br/>elementary flow"] --> Farm["Wheat farming"]
    Water["Water use<br/>elementary flow"] --> Farm
    Wheat["Wheat grain<br/>product flow"] --> Mill["Flour milling"]
    Farm --> Wheat
    Transport["Lorry transport"] --> Service["Transport service<br/>product flow"]
    Service --> Mill
    Mill --> Flour["Wheat flour<br/>reference flow"]
```

The project also includes a real-data ingestion pipeline for ELCD 3.2:

```mermaid
flowchart LR
    A["openLCA .zolca archive"] --> B["openLCA ILCD export"]
    B --> C["inspect_ilcd.py"]
    C --> D["parse_ilcd.py<br/>XML to normalized JSON"]
    D --> E["transform.py<br/>JSON to table-shaped records"]
    E --> F["load_to_postgres.py<br/>bulk upsert/load"]
    F --> G["PostgreSQL LCA database"]
    G --> H["SQL validation + analysis queries"]
```

## 3. Tech Used

The project uses a focused, data-engineering-oriented stack:

| Area                 | Technology                                      |
| -------------------- | ----------------------------------------------- |
| Database             | PostgreSQL 16                                   |
| Local infrastructure | Docker Compose                                  |
| Schema               | SQL DDL, PostgreSQL enums, constraints, indexes |
| Data pipeline        | Python 3                                        |
| XML parsing          | Python `xml.etree.ElementTree`                  |
| Database loading     | `psycopg2`, `execute_values` bulk inserts       |
| Environment config   | `.env`, `python-dotenv`                         |
| Workflow automation  | Makefile                                        |
| Source data          | ELCD 3.2 from openLCA Nexus                     |
| Source format        | openLCA `.zolca`, exported to ILCD XML          |
| Query layer          | Standalone analytical SQL files                 |
| Documentation        | README files, schema docs, DBML/PDF ER diagram  |

The database is initialized automatically by Docker Compose using the SQL files mounted into `/docker-entrypoint-initdb.d`.

```mermaid
flowchart TD
    Compose["docker-compose.yml"] --> PG["PostgreSQL container"]
    Schema["schema/*.sql"] --> PG
    Env[".env"] --> Compose
    Volume["postgres_data volume"] --> PG
```

## 4. Implementation Details Visually Explained

### Core Data Model

The schema is centered around `processes`, `flows`, and `exchanges`.

```mermaid
erDiagram
    GEOGRAPHIES ||--o{ PROCESSES : locates
    CATEGORIES ||--o{ PROCESSES : classifies
    UNITS ||--o{ FLOWS : default_unit
    UNITS ||--o{ EXCHANGES : exchange_unit
    PROCESSES ||--o{ EXCHANGES : has
    FLOWS ||--o{ EXCHANGES : moves_through
    PROCESSES ||--o{ IMPACT_RESULTS : scored_by
    IMPACT_CATEGORIES ||--o{ IMPACT_RESULTS : defines

    PROCESSES {
        int id
        text name
        int category_id
        int geography_id
        smallint reference_year
        text source_dataset
        text external_id
    }

    FLOWS {
        int id
        text name
        enum flow_type
        int unit_id
        text cas_number
        text external_id
    }

    EXCHANGES {
        int id
        int process_id
        int flow_id
        enum direction
        numeric amount
        int unit_id
        boolean is_reference_flow
    }

    IMPACT_RESULTS {
        int id
        int process_id
        int impact_category_id
        numeric value
    }
```

### Flow Types

The schema distinguishes between three kinds of flows:

```mermaid
flowchart TD
    Flow["Flow"] --> Product["product<br/>moves between processes"]
    Flow --> Elementary["elementary<br/>crosses nature/system boundary"]
    Flow --> Waste["waste<br/>sent to treatment"]

    Product --> Example1["wheat grain, electricity, transport service"]
    Elementary --> Example2["CO2 to air, nitrate to water, water abstraction"]
    Waste --> Example3["scrap, disposal output"]
```

The distinction is important because product flows let the database walk upstream supply chains, while elementary flows are the environmental inventory outputs that feed impact assessment.

### Exchange Direction

Each exchange says whether a process consumes or produces a flow.

```mermaid
flowchart LR
    InputFlow["Input flow"] -->|direction = input| Process["Process"]
    Process -->|direction = output| OutputFlow["Output flow"]
    Process -->|reference output| Ref["Reference flow<br/>functional unit"]
```

For example:

| Process       | Direction | Flow        | Meaning                      |
| ------------- | --------- | ----------- | ---------------------------- |
| Flour milling | input     | wheat grain | wheat consumed by the mill   |
| Flour milling | output    | wheat flour | product produced by the mill |
| Flour milling | output    | CO2         | emission from the process    |

### Data Pipeline

The ELCD pipeline is split into stages so each step has a narrow responsibility.

```mermaid
flowchart TD
    Inspect["inspect_ilcd.py"] --> Parse["parse_ilcd.py"]
    Parse --> Transform["transform.py"]
    Transform --> Load["load_to_postgres.py"]
    Load --> Validate["queries/07_elcd_validation.sql"]

    Inspect --> I1["Reports export contents"]
    Parse --> P1["Extracts process, flow, unit, exchange metadata"]
    Transform --> T1["Resolves categories, units, flow types, geographies"]
    Load --> L1["Loads in dependency order"]
    Validate --> V1["Checks counts, reference flows, joins"]
```

The loader inserts records in dependency order:

```mermaid
flowchart LR
    G["geographies"] --> P["processes"]
    C["categories"] --> P
    U["units"] --> F["flows"]
    U --> E["exchanges"]
    F --> E
    P --> E
```

The load step is designed to be rerunnable. It upserts stable entities like geographies, units, flows, and processes, then replaces exchange rows for the loaded processes so repeated runs do not duplicate graph edges.

### Integrity Rules

The schema includes constraints that keep the graph valid:

| Rule                                      | Purpose                                                     |
| ----------------------------------------- | ----------------------------------------------------------- |
| `flow_type_enum`                          | restricts flows to `product`, `elementary`, or `waste`      |
| `direction_enum`                          | restricts exchanges to `input` or `output`                  |
| nonzero exchange amount                   | avoids meaningless graph edges                              |
| reference flow must be output             | prevents an input from defining the process output          |
| one reference flow per process            | ensures each process has at most one functional-unit output |
| unique impact result per process/category | prevents duplicate LCIA scores                              |

### Analytical Query Layer

```mermaid
flowchart TD
    Q1["01_basic_lookups.sql"] --> Q2["02_exchanges_by_process.sql"]
    Q2 --> Q3["03_reference_flows.sql"]
    Q3 --> Q4["04_elementary_flows.sql"]
    Q4 --> Q5["05_impact_results_ranked.sql"]
    Q5 --> Q6["06_supply_chain_graph.sql"]
    Q6 --> Q7["07_elcd_validation.sql"]
```

The centerpiece is the recursive supply-chain query. It starts from a process, finds its product inputs, then finds upstream processes whose reference outputs match those inputs.

```mermaid
flowchart TD
    Start["Starting process"] --> Inputs["Find product inputs"]
    Inputs --> Match["Match input flow to upstream reference output"]
    Match --> Upstream["Add upstream process"]
    Upstream --> More["Repeat recursively"]
    More --> Stop["Stop when no more resolvable product inputs"]
```

## Current State

The project includes:

- A normalized PostgreSQL schema for LCA inventory data.
- Docker-based local database setup.
- Seed data for local testing.
- A Python ELCD 3.2 parsing, transformation, and loading pipeline.
- SQL queries for validation, inventory inspection, impact ranking, and recursive supply-chain traversal.
- Documentation for schema design and data sources.
````
