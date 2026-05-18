PYTHON := python3
POSTGRES_SERVICE := postgres
POSTGRES_USER := lca_user
POSTGRES_DB := lca_supply_chain
ILCD_DIR := data/raw/elcd_3_2/exported/ilcd/ILCD

.PHONY: help up down reset inspect parse transform load pipeline validate psql

help:
	@echo "Available targets:"
	@echo "  make up         - start the PostgreSQL container"
	@echo "  make down       - stop the PostgreSQL container"
	@echo "  make reset      - rebuild the database volume from scratch"
	@echo "  make inspect    - inspect the ILCD export folder"
	@echo "  make parse      - parse ILCD XML into processed JSON"
	@echo "  make transform  - transform parsed JSON into table-shaped JSON"
	@echo "  make load       - load transformed ELCD data into PostgreSQL"
	@echo "  make pipeline   - run inspect, parse, transform, and load"
	@echo "  make validate   - run the ELCD validation SQL queries"
	@echo "  make psql       - open a psql shell in the PostgreSQL container"

up:
	docker compose up -d

down:
	docker compose down

reset:
	docker compose down -v
	docker compose up -d

inspect:
	$(PYTHON) loader/inspect_ilcd.py $(ILCD_DIR)

parse:
	$(PYTHON) loader/parse_ilcd.py $(ILCD_DIR)

transform:
	$(PYTHON) loader/transform.py

load:
	$(PYTHON) loader/load_to_postgres.py

pipeline: inspect parse transform load

validate:
	docker compose exec -T $(POSTGRES_SERVICE) psql -U $(POSTGRES_USER) -d $(POSTGRES_DB) < queries/07_elcd_validation.sql

psql:
	docker compose exec $(POSTGRES_SERVICE) psql -U $(POSTGRES_USER) -d $(POSTGRES_DB)
