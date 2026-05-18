# LCA Supply Chain Database

Database modeling product life cycles (materials, processes, emissions, suppliers) using real ELCD data.

### What this is

A PostgreSQL database for storing and querying LCA (Life Cycle Assessment) inventory data. The schema models industrial supply chains as a graph: processes are the nodes, flows are the things moving between them, and exchanges are the edges. On top of that sits an impact layer for storing pre-calculated environmental scores per process.

The project includes a small seed dataset for local testing and now also supports a first working ELCD 3.2 pipeline using an openLCA ILCD export.

### Project structure

```
LCA_Supply_Chain_Database/
│
├── docker-compose.yml
├── .env                  # local credentials, not committed
├── .env.example          # safe template, committed
├── .gitignore
├── README.md
│
├── data/
│   ├── raw/
│   │   └── elcd_3_2/
│   │       ├── original_download/   # local .zolca archive, not committed
│   │       └── exported/
│   │           ├── ilcd/            # openLCA ILCD export
│   │           └── jsonld/          # optional future JSON-LD export
│   └── processed/
│       └── elcd_3_2/                # parser and transform outputs, not committed
├── docs/
│   └── data_sources.md
├── loader/
│   ├── inspect_ilcd.py
│   ├── parse_ilcd.py
│   ├── transform.py
│   └── load_to_postgres.py
├── queries/
│   └── ...
└── schema/
    ├── 01_create_tables.sql
    ├── 02_constraints.sql
    ├── 03_seed_data.sql
    ├── ER_diagram.pdf
    └── README.md
```

### Getting started

Copy the environment template and set a password:

```bash
cp .env.example .env
# Open .env and replace change_me with a real password in both places
```

Start the database:

```bash
docker compose up -d
```

PostgreSQL will initialize the schema and load the seed data automatically on first run.

### Current pipeline

The current ELCD pipeline works in four stages:

1. `inspect_ilcd.py` checks the exported ILCD folder and reports what is inside.
2. `parse_ilcd.py` extracts XML data into normalized JSON files.
3. `transform.py` reshapes that parsed data into table-like records for PostgreSQL.
4. `load_to_postgres.py` loads the transformed records into the database.

At the moment, the ELCD load has been validated with:

- 7 ELCD processes
- 47,995 ELCD flows
- 2,278 ELCD exchanges

### Useful commands

Check the container is running and healthy:

```bash
docker compose ps
docker compose logs postgres
```

Connect with psql:

```bash
docker compose exec postgres psql -U lca_user -d lca_supply_chain
```

Stop the container without losing data:

```bash
docker compose down
```

Wipe everything and reinitialize from the SQL files:

```bash
docker compose down -v
docker compose up -d
```

The SQL files only run on first initialization, so if you edit the schema you need `down -v` to see the changes.

### Data pipeline layout

The raw ELCD 3.2 archive should stay under `data/raw/elcd_3_2/original_download/`. Because the downloaded source is an openLCA `.zolca` archive, the pipeline works like this:

1. Import the `.zolca` archive into openLCA.
2. Export it to `data/raw/elcd_3_2/exported/ilcd/`.
3. Run the Python pipeline to inspect, parse, transform, and load the data.
4. Write intermediate outputs to `data/processed/elcd_3_2/`.

Raw and processed data directories are intentionally gitignored. Only placeholder `.gitkeep` files are committed so the structure stays visible.

### Pipeline commands

Once the ILCD export is in place and Docker is running:

```bash
python3 loader/inspect_ilcd.py data/raw/elcd_3_2/exported/ilcd/ILCD
python3 loader/parse_ilcd.py data/raw/elcd_3_2/exported/ilcd/ILCD
python3 loader/transform.py
python3 loader/load_to_postgres.py
```

The last step expects the PostgreSQL container to already be running.

### Port conflict

If port 5432 is already in use, change `POSTGRES_PORT` to `5433` in `.env` and restart the container.
