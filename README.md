# LCA Supply Chain Database

Database modeling product life cycles (materials, processes, emissions, suppliers) using real ELCD data.

### What this is

A PostgreSQL database for storing and querying LCA (Life Cycle Assessment) inventory data. The schema models industrial supply chains as a graph: processes are the nodes, flows are the things moving between them, and exchanges are the edges. On top of that sits an impact layer for storing pre-calculated environmental scores per process.

The seed data models a simple wheat-to-flour supply chain (wheat farming → lorry transport → flour milling) with illustrative values. Real Agribalyse data will replace this later.

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
└── schema/
    ├── 01_create_tables.sql
    ├── 02_constraints.sql
    ├── 03_seed_data.sql
    ├── ER_diagram.pdf
    └── README.md
```

### Database Schema
![ER-diagram](schema/ER_diagram.pdf)

### Getting started

Copy the environment template and set a password:

```bash
cp .env.example .env
# Open .env and replace change_me with a real password in both places
```

Start the database

```bash
docker compose up -d
```

That's it. PostgreSQL will initialize the schema and load the seed data automatically on first run.

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

The SQL fiels only run on first initialization, so if you edit the schema you need `down -v` to see the changes.

### Port conflict

If port 5432 is already in use, change `POSTGRES_PORT` to `5433` in `.env` and restart the container.
