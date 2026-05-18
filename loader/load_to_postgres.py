"""Load transformed ELCD records into PostgreSQL.

This stage reads the table-shaped JSON artifacts produced by transform.py and
inserts them into the project database in dependency order:

1. geographies
2. categories
3. units
4. flows
5. processes
6. exchanges

The loader is designed to be rerunnable. It upserts lookup tables, upserts
flows and processes by external_id, and replaces exchanges for the target
processes before inserting fresh exchange rows.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
from typing import Any

from dotenv import load_dotenv
import psycopg2
from psycopg2.extras import execute_values


DEFAULT_INPUT_DIR = Path("data/processed/elcd_3_2/transformed")
DEFAULT_BATCH_SIZE = 1000
SOURCE_DATASET = "ELCD 3.2 via openLCA ILCD export"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Load transformed ELCD JSON records into PostgreSQL."
    )
    parser.add_argument(
        "input_dir",
        nargs="?",
        default=str(DEFAULT_INPUT_DIR),
        help=f"Directory containing transformed JSON files. Defaults to {DEFAULT_INPUT_DIR}.",
    )
    parser.add_argument(
        "--batch-size",
        type=int,
        default=DEFAULT_BATCH_SIZE,
        help=f"Batch size for bulk inserts. Defaults to {DEFAULT_BATCH_SIZE}.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Validate files and print load counts without writing to PostgreSQL.",
    )
    return parser.parse_args()


def read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def load_input(input_dir: Path) -> dict[str, Any]:
    required = {
        "geographies": "geographies.json",
        "categories": "categories.json",
        "units": "units.json",
        "flows": "flows.json",
        "processes": "processes.json",
        "exchanges": "exchanges.json",
        "summary": "summary.json",
    }
    payload: dict[str, Any] = {}
    for key, filename in required.items():
        path = input_dir / filename
        if not path.exists():
            raise FileNotFoundError(f"Required input file not found: {path}")
        payload[key] = read_json(path)
    return payload


def connect():
    load_dotenv()
    database_url = os.getenv("DATABASE_URL")
    if database_url:
        return psycopg2.connect(database_url)

    required = ["POSTGRES_DB", "POSTGRES_USER", "POSTGRES_PASSWORD", "POSTGRES_PORT"]
    missing = [key for key in required if not os.getenv(key)]
    if missing:
        raise RuntimeError(
            f"Missing database configuration in environment/.env: {', '.join(missing)}"
        )

    # Fall back to the discrete env vars used by the Docker Compose setup.
    return psycopg2.connect(
        dbname=os.environ["POSTGRES_DB"],
        user=os.environ["POSTGRES_USER"],
        password=os.environ["POSTGRES_PASSWORD"],
        host="localhost",
        port=os.environ["POSTGRES_PORT"],
    )


def fetch_map(cursor, query: str, key_index: int = 0, value_index: int = 1) -> dict[Any, Any]:
    cursor.execute(query)
    return {row[key_index]: row[value_index] for row in cursor.fetchall()}


def chunked(items: list[Any], size: int) -> list[list[Any]]:
    return [items[index:index + size] for index in range(0, len(items), size)]


def assert_exchange_amount_precision(cursor) -> None:
    cursor.execute(
        """
        SELECT numeric_precision, numeric_scale
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'exchanges'
          AND column_name = 'amount'
        """
    )
    row = cursor.fetchone()
    if row is None:
        raise RuntimeError("Could not inspect public.exchanges.amount column.")

    precision, scale = row
    if scale is None:
        return
    if scale < 28:
        raise RuntimeError(
            "The database schema is using an outdated exchanges.amount precision "
            f"(NUMERIC({precision}, {scale})). ELCD exchange values require at least "
            "28 decimal places. Reinitialize the database with the updated schema or run "
            "ALTER TABLE exchanges ALTER COLUMN amount TYPE NUMERIC(38, 28);"
        )


def upsert_geographies(cursor, geographies: list[dict[str, Any]]) -> dict[str, int]:
    rows = [(item["code"], item["name"], item["is_global"]) for item in geographies]
    if rows:
        execute_values(
            cursor,
            """
            INSERT INTO geographies (code, name, is_global)
            VALUES %s
            ON CONFLICT (code) DO UPDATE
            SET name = EXCLUDED.name,
                is_global = EXCLUDED.is_global
            """,
            rows,
        )
    return fetch_map(cursor, "SELECT code, id FROM geographies")


def upsert_categories(cursor, categories: list[dict[str, Any]]) -> dict[str, int]:
    id_by_external: dict[str, int] = {}
    # Categories depend on parent categories, so we load them level by level.
    for category in sorted(categories, key=lambda item: item["level"]):
        parent_external_id = category.get("parent_external_id")
        parent_id = id_by_external.get(parent_external_id) if parent_external_id else None
        cursor.execute(
            """
            INSERT INTO categories (name, parent_id, full_path)
            VALUES (%s, %s, %s)
            ON CONFLICT DO NOTHING
            RETURNING id
            """,
            (category["name"], parent_id, category["full_path"]),
        )
        row = cursor.fetchone()
        if row is not None:
            category_id = row[0]
        else:
            if parent_id is None:
                cursor.execute(
                    "SELECT id FROM categories WHERE parent_id IS NULL AND name = %s",
                    (category["name"],),
                )
            else:
                cursor.execute(
                    "SELECT id FROM categories WHERE parent_id = %s AND name = %s",
                    (parent_id, category["name"]),
                )
            existing = cursor.fetchone()
            if existing is None:
                raise RuntimeError(f"Could not resolve category after upsert: {category}")
            category_id = existing[0]
            cursor.execute(
                "UPDATE categories SET full_path = %s WHERE id = %s",
                (category["full_path"], category_id),
            )
        id_by_external[category["external_id"]] = category_id
    return id_by_external


def upsert_units(cursor, units: list[dict[str, Any]]) -> dict[str, int]:
    rows = [(item["name"], item["dimension"]) for item in units]
    if rows:
        execute_values(
            cursor,
            """
            INSERT INTO units (name, dimension)
            VALUES %s
            ON CONFLICT (name) DO UPDATE
            SET dimension = COALESCE(EXCLUDED.dimension, units.dimension)
            """,
            rows,
        )
    cursor.execute("SELECT id, name FROM units")
    id_by_name = {name: unit_id for unit_id, name in cursor.fetchall()}
    return {item["external_id"]: id_by_name[item["name"]] for item in units if item["name"] in id_by_name}


def upsert_flows(cursor, flows: list[dict[str, Any]], unit_id_by_external: dict[str, int], batch_size: int) -> dict[str, int]:
    rows = [
        (
            item["name"],
            item["description"],
            item["flow_type"],
            unit_id_by_external.get(item["unit_external_id"]),
            item["cas_number"],
            item["external_id"],
        )
        for item in flows
    ]
    for batch in chunked(rows, batch_size):
        execute_values(
            cursor,
            """
            INSERT INTO flows (name, description, flow_type, unit_id, cas_number, external_id)
            VALUES %s
            ON CONFLICT (external_id) DO UPDATE
            SET name = EXCLUDED.name,
                description = EXCLUDED.description,
                flow_type = EXCLUDED.flow_type,
                unit_id = EXCLUDED.unit_id,
                cas_number = EXCLUDED.cas_number
            """,
            batch,
        )
    return fetch_map(cursor, "SELECT external_id, id FROM flows WHERE external_id IS NOT NULL")


def upsert_processes(
    cursor,
    processes: list[dict[str, Any]],
    geography_id_by_code: dict[str, int],
    category_id_by_external: dict[str, int],
    batch_size: int,
) -> dict[str, int]:
    rows = [
        (
            item["name"],
            item["description"],
            category_id_by_external.get(item["category_external_id"]),
            geography_id_by_code.get(item["geography_code"]),
            item["reference_year"],
            item["source_dataset"],
            item["external_id"],
        )
        for item in processes
    ]
    for batch in chunked(rows, batch_size):
        execute_values(
            cursor,
            """
            INSERT INTO processes (
                name, description, category_id, geography_id, reference_year, source_dataset, external_id
            )
            VALUES %s
            ON CONFLICT (external_id) DO UPDATE
            SET name = EXCLUDED.name,
                description = EXCLUDED.description,
                category_id = EXCLUDED.category_id,
                geography_id = EXCLUDED.geography_id,
                reference_year = EXCLUDED.reference_year,
                source_dataset = EXCLUDED.source_dataset
            """,
            batch,
        )
    return fetch_map(cursor, "SELECT external_id, id FROM processes WHERE external_id IS NOT NULL")


def replace_exchanges(
    cursor,
    exchanges: list[dict[str, Any]],
    process_id_by_external: dict[str, int],
    flow_id_by_external: dict[str, int],
    unit_id_by_external: dict[str, int],
    batch_size: int,
) -> int:
    # Treat exchanges as replaceable per loaded process so reruns stay simple
    # and we avoid duplicate edges.
    process_ids = sorted(
        {
            process_id_by_external[item["process_external_id"]]
            for item in exchanges
            if item["process_external_id"] in process_id_by_external
        }
    )
    if process_ids:
        cursor.execute("DELETE FROM exchanges WHERE process_id = ANY(%s)", (process_ids,))

    rows = [
        (
            process_id_by_external[item["process_external_id"]],
            flow_id_by_external[item["flow_external_id"]],
            item["direction"],
            item["amount"],
            unit_id_by_external.get(item["unit_external_id"]),
            item["is_reference_flow"],
            item["comment"],
        )
        for item in exchanges
    ]
    inserted = 0
    for batch in chunked(rows, batch_size):
        execute_values(
            cursor,
            """
            INSERT INTO exchanges (
                process_id, flow_id, direction, amount, unit_id, is_reference_flow, comment
            )
            VALUES %s
            """,
            batch,
        )
        inserted += len(batch)
    return inserted


def build_summary(data: dict[str, Any]) -> dict[str, Any]:
    return {
        "source_dataset": SOURCE_DATASET,
        "counts": {
            "geographies": len(data["geographies"]),
            "categories": len(data["categories"]),
            "units": len(data["units"]),
            "flows": len(data["flows"]),
            "processes": len(data["processes"]),
            "exchanges": len(data["exchanges"]),
        },
    }


def main() -> int:
    args = parse_args()
    input_dir = Path(args.input_dir).expanduser().resolve()
    data = load_input(input_dir)
    summary = build_summary(data)

    if args.dry_run:
        print(json.dumps({"dry_run": True, **summary}, indent=2))
        return 0

    connection = connect()
    try:
        connection.autocommit = False
        with connection.cursor() as cursor:
            # The load order mirrors the schema dependencies.
            assert_exchange_amount_precision(cursor)
            geography_id_by_code = upsert_geographies(cursor, data["geographies"])
            category_id_by_external = upsert_categories(cursor, data["categories"])
            unit_id_by_external = upsert_units(cursor, data["units"])
            flow_id_by_external = upsert_flows(
                cursor, data["flows"], unit_id_by_external, args.batch_size
            )
            process_id_by_external = upsert_processes(
                cursor,
                data["processes"],
                geography_id_by_code,
                category_id_by_external,
                args.batch_size,
            )
            inserted_exchanges = replace_exchanges(
                cursor,
                data["exchanges"],
                process_id_by_external,
                flow_id_by_external,
                unit_id_by_external,
                args.batch_size,
            )
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()

    print(
        json.dumps(
            {
                "loaded": True,
                **summary,
                "exchange_rows_inserted": inserted_exchanges,
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
