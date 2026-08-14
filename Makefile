PYTHON := python3
POSTGRES_SERVICE := postgres
POSTGRES_USER := lca_user
POSTGRES_DB := lca_supply_chain
ILCD_DIR := data/raw/elcd_3_2/exported/ilcd/ILCD

.PHONY: help up down reset inspect parse transform load pipeline validate psql check-precision check-units calculate-impacts validate-lcia validate-lcia-seed

help:
	@echo "Available targets:"
	@echo "  make up                  - start the PostgreSQL container"
	@echo "  make down                - stop the PostgreSQL container"
	@echo "  make reset               - rebuild the database volume from scratch"
	@echo "  make inspect             - inspect the ILCD export folder"
	@echo "  make parse               - parse ILCD XML into processed JSON"
	@echo "  make transform           - transform parsed JSON into table-shaped JSON"
	@echo "  make load                - load transformed ELCD data into PostgreSQL"
	@echo "  make pipeline            - run inspect, parse, transform, and load"
	@echo "  make validate            - run the ELCD validation SQL queries"
	@echo "  make check-precision     - regression check: amounts round-trip without float rounding"
	@echo "  make check-units         - run unit conversion / dimensional-compatibility checks"
	@echo "  make calculate-impacts   - (re)derive impact_results from exchanges x characterization_factors"
	@echo "  make validate-lcia       - run the LCIA calculation + rollup validation queries against the DB"
	@echo "  make validate-lcia-seed  - independent Python reference computation for the seed LCIA numbers"
	@echo "  make psql                - open a psql shell in the PostgreSQL container"

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

check-precision:
	$(PYTHON) loader/check_precision.py

check-units:
	docker compose exec -T $(POSTGRES_SERVICE) psql -U $(POSTGRES_USER) -d $(POSTGRES_DB) < queries/08_unit_conversion_checks.sql

calculate-impacts:
	docker compose exec -T $(POSTGRES_SERVICE) psql -U $(POSTGRES_USER) -d $(POSTGRES_DB) -c "CALL upsert_direct_impacts_for_all_processes();"

validate-lcia:
	docker compose exec -T $(POSTGRES_SERVICE) psql -U $(POSTGRES_USER) -d $(POSTGRES_DB) < queries/09_lcia_calculation_validation.sql
	docker compose exec -T $(POSTGRES_SERVICE) psql -U $(POSTGRES_USER) -d $(POSTGRES_DB) < queries/10_supply_chain_rollup_examples.sql

validate-lcia-seed:
	$(PYTHON) loader/validate_lcia_seed.py

psql:
	docker compose exec $(POSTGRES_SERVICE) psql -U $(POSTGRES_USER) -d $(POSTGRES_DB)
