"""Transform parsed ILCD JSON into database-shaped records.

This stage converts the parser output into table-oriented JSON artifacts that
match the PostgreSQL schema more closely. It does not write to PostgreSQL yet;
instead it resolves references and emits load-friendly records keyed by stable
external identifiers.
"""

from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path
from typing import Any


DEFAULT_INPUT_DIR = Path("data/processed/elcd_3_2")
DEFAULT_OUTPUT_DIR = Path("data/processed/elcd_3_2/transformed")
SOURCE_DATASET = "ELCD 3.2 via openLCA ILCD export"

GEOGRAPHY_NAMES = {
    "GLO": "Global",
    "RER": "Europe",
    "CH": "Switzerland",
    "DE": "Germany",
    "FR": "France",
    "US": "United States",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Transform parsed ILCD JSON into database-shaped JSON artifacts."
    )
    parser.add_argument(
        "input_dir",
        nargs="?",
        default=str(DEFAULT_INPUT_DIR),
        help=f"Directory containing parse_ilcd.py outputs. Defaults to {DEFAULT_INPUT_DIR}.",
    )
    parser.add_argument(
        "--output-dir",
        default=str(DEFAULT_OUTPUT_DIR),
        help=f"Directory for transformed outputs. Defaults to {DEFAULT_OUTPUT_DIR}.",
    )
    return parser.parse_args()


def read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")


def infer_dimension(unit_group_name: str | None) -> str | None:
    if not unit_group_name:
        return None

    normalized = unit_group_name.lower()
    if "mass" in normalized:
        return "mass"
    if "energy" in normalized:
        return "energy"
    if "volume" in normalized:
        return "volume"
    if "area" in normalized and "length" not in normalized:
        return "area"
    if "length" in normalized:
        return "length"
    if "time" in normalized:
        return "time"
    if "currency" in normalized:
        return "currency"
    if "item" in normalized or "piece" in normalized:
        return "item"
    return None


def map_flow_type(flow: dict[str, Any]) -> str:
    dataset_type = (flow.get("dataset_type") or "").lower()
    class_names = [str(item.get("name") or "").lower() for item in flow.get("classifications", [])]

    if "elementary flow" in dataset_type or any("elementary flows" == name for name in class_names):
        return "elementary"
    if "waste" in dataset_type or any("waste" in name for name in class_names):
        return "waste"
    return "product"


def geography_record(code: str) -> dict[str, Any]:
    return {
        "code": code,
        "name": GEOGRAPHY_NAMES.get(code, code),
        "is_global": code == "GLO",
    }


def build_categories(processes: list[dict[str, Any]]) -> list[dict[str, Any]]:
    categories_by_id: dict[str, dict[str, Any]] = {}

    # Rebuild the category tree from the ordered classification levels stored
    # on each parsed process.
    for process in processes:
        classes = sorted(
            [item for item in process.get("classifications", []) if item.get("id") and item.get("name")],
            key=lambda item: int(item.get("level") or 0),
        )
        full_parts: list[str] = []
        parent_id: str | None = None
        for item in classes:
            category_id = item["id"]
            full_parts.append(item["name"])
            if category_id not in categories_by_id:
                categories_by_id[category_id] = {
                    "external_id": category_id,
                    "name": item["name"],
                    "parent_external_id": parent_id,
                    "full_path": "/".join(full_parts),
                    "level": int(item.get("level") or 0),
                }
            parent_id = category_id

    return sorted(categories_by_id.values(), key=lambda item: (item["level"], item["full_path"]))


def build_units(unit_groups: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], dict[str, dict[str, Any]], dict[str, dict[str, Any]]]:
    units_by_uuid: dict[str, dict[str, Any]] = {}
    unit_group_by_uuid: dict[str, dict[str, Any]] = {}
    reference_unit_by_group_uuid: dict[str, dict[str, Any]] = {}

    # Flatten ILCD unit groups into unit records while preserving the link
    # back to the reference unit in each group.
    for group in unit_groups:
        group_uuid = group["uuid"]
        unit_group_by_uuid[group_uuid] = group
        dimension = infer_dimension(group.get("name"))
        reference_internal_id = group.get("reference_unit_internal_id")
        for unit in group.get("units", []):
            unit_uuid = unit.get("uuid")
            if not unit_uuid:
                continue
            record = units_by_uuid.setdefault(
                unit_uuid,
                {
                    "external_id": unit_uuid,
                    "name": unit.get("name"),
                    "dimension": dimension,
                    "source_unit_group_uuid": group_uuid,
                    "source_unit_group_name": group.get("name"),
                    "conversion_to_reference": unit.get("mean_value"),
                },
            )
            if record.get("dimension") is None and dimension is not None:
                record["dimension"] = dimension
            if unit.get("internal_id") == reference_internal_id:
                reference_unit_by_group_uuid[group_uuid] = record

    units = list(units_by_uuid.values())

    # Some ILCD exports reuse short unit labels across different meanings
    # (for example "a" can mean both area and time). Disambiguate only the
    # collided names so the relational schema can keep units.name unique.
    name_counts = Counter(item["name"] for item in units if item.get("name"))
    for item in units:
        name = item.get("name")
        if not name or name_counts[name] == 1:
            continue
        group_name = item.get("source_unit_group_name") or item.get("dimension") or "unit"
        item["name"] = f"{name} [{group_name}]"

    # If a collision still remains after using the unit-group name, append a
    # short external-id suffix as a final stable fallback.
    disambiguated_counts = Counter(item["name"] for item in units if item.get("name"))
    for item in units:
        name = item.get("name")
        if not name or disambiguated_counts[name] == 1:
            continue
        item["name"] = f"{name} ({item['external_id'][:8]})"

    units = sorted(units, key=lambda item: item["name"] or item["external_id"])
    return units, units_by_uuid, reference_unit_by_group_uuid


def build_flows(
    flows: list[dict[str, Any]],
    flow_properties: list[dict[str, Any]],
    reference_unit_by_group_uuid: dict[str, dict[str, Any]],
) -> tuple[list[dict[str, Any]], dict[str, dict[str, Any]], list[dict[str, Any]]]:
    flow_property_by_uuid = {item["uuid"]: item for item in flow_properties if item.get("uuid")}
    transformed: list[dict[str, Any]] = []
    flow_by_uuid: dict[str, dict[str, Any]] = {}
    unresolved: list[dict[str, Any]] = []

    # Resolve each flow's reference property to a default unit so the loader
    # can map flows directly into the relational schema.
    for flow in flows:
        reference_property_uuid = None
        for property_record in flow.get("flow_properties", []):
            if property_record.get("internal_id") == flow.get("reference_flow_property_internal_id"):
                reference_property_uuid = property_record.get("flow_property_uuid")
                break
        if reference_property_uuid is None and flow.get("flow_properties"):
            reference_property_uuid = flow["flow_properties"][0].get("flow_property_uuid")

        flow_property = flow_property_by_uuid.get(reference_property_uuid) if reference_property_uuid else None
        reference_unit = None
        if flow_property is not None:
            reference_unit = reference_unit_by_group_uuid.get(flow_property.get("reference_unit_group_uuid"))

        if reference_unit is None:
            unresolved.append(
                {
                    "flow_uuid": flow.get("uuid"),
                    "flow_name": flow.get("name"),
                    "reference_flow_property_uuid": reference_property_uuid,
                }
            )

        record = {
            "external_id": flow.get("uuid"),
            "name": flow.get("name"),
            "description": None,
            "flow_type": map_flow_type(flow),
            "unit_external_id": None if reference_unit is None else reference_unit.get("external_id"),
            "cas_number": flow.get("cas_number"),
            "reference_flow_property_uuid": reference_property_uuid,
            "source_dataset": SOURCE_DATASET,
        }
        transformed.append(record)
        if record["external_id"]:
            flow_by_uuid[record["external_id"]] = record

    transformed.sort(key=lambda item: item["name"] or item["external_id"])
    return transformed, flow_by_uuid, unresolved


def build_processes(
    processes: list[dict[str, Any]],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], dict[str, dict[str, Any]]]:
    transformed: list[dict[str, Any]] = []
    geographies_by_code: dict[str, dict[str, Any]] = {}
    process_by_uuid: dict[str, dict[str, Any]] = {}

    for process in processes:
        classes = sorted(
            [item for item in process.get("classifications", []) if item.get("id")],
            key=lambda item: int(item.get("level") or 0),
        )
        deepest_category_id = classes[-1]["id"] if classes else None
        geography_code = process.get("geography_code")
        if geography_code:
            geographies_by_code.setdefault(geography_code, geography_record(geography_code))

        try:
            reference_year = int(process["reference_year"]) if process.get("reference_year") else None
        except ValueError:
            reference_year = None

        record = {
            "external_id": process.get("uuid"),
            "name": process.get("name"),
            "description": process.get("technology_description"),
            "category_external_id": deepest_category_id,
            "geography_code": geography_code,
            "reference_year": reference_year,
            "source_dataset": SOURCE_DATASET,
        }
        transformed.append(record)
        if record["external_id"]:
            process_by_uuid[record["external_id"]] = record

    transformed.sort(key=lambda item: item["name"] or item["external_id"])
    geographies = sorted(geographies_by_code.values(), key=lambda item: item["code"])
    return transformed, geographies, process_by_uuid


def build_exchanges(
    processes: list[dict[str, Any]],
    flow_by_uuid: dict[str, dict[str, Any]],
    units_by_uuid: dict[str, dict[str, Any]],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    transformed: list[dict[str, Any]] = []
    unresolved: list[dict[str, Any]] = []

    # Exchanges stay attached to their source process until this step, where
    # we reshape them into table-style records for loading.
    for process in processes:
        process_uuid = process.get("uuid")
        for exchange in process.get("exchanges", []):
            flow_uuid = exchange.get("flow_uuid")
            unit_uuid = exchange.get("unit_uuid")
            if flow_uuid not in flow_by_uuid:
                unresolved.append(
                    {
                        "process_uuid": process_uuid,
                        "exchange_internal_id": exchange.get("internal_id"),
                        "missing": "flow",
                        "flow_uuid": flow_uuid,
                    }
                )
            if unit_uuid and unit_uuid not in units_by_uuid:
                unresolved.append(
                    {
                        "process_uuid": process_uuid,
                        "exchange_internal_id": exchange.get("internal_id"),
                        "missing": "unit",
                        "unit_uuid": unit_uuid,
                    }
                )

            transformed.append(
                {
                    "process_external_id": process_uuid,
                    "flow_external_id": flow_uuid,
                    "direction": exchange.get("direction"),
                    "amount": exchange.get("amount"),
                    "unit_external_id": unit_uuid,
                    "is_reference_flow": bool(exchange.get("is_reference_flow")),
                    "comment": exchange.get("flow_name"),
                    "source_exchange_internal_id": exchange.get("internal_id"),
                    "flow_property_uuid": exchange.get("property_uuid"),
                }
            )

    return transformed, unresolved


def main() -> int:
    args = parse_args()
    input_dir = Path(args.input_dir).expanduser().resolve()
    output_dir = Path(args.output_dir).expanduser().resolve()

    if not input_dir.exists() or not input_dir.is_dir():
        raise SystemExit(f"Input directory does not exist or is not a directory: {input_dir}")

    processes = read_json(input_dir / "processes.json")
    flows = read_json(input_dir / "flows.json")
    flow_properties = read_json(input_dir / "flow_properties.json")
    unit_groups = read_json(input_dir / "unit_groups.json")

    categories = build_categories(processes)
    units, units_by_uuid, reference_unit_by_group_uuid = build_units(unit_groups)
    transformed_flows, flow_by_uuid, unresolved_flow_units = build_flows(
        flows, flow_properties, reference_unit_by_group_uuid
    )
    transformed_processes, geographies, process_by_uuid = build_processes(processes)
    transformed_exchanges, unresolved_exchange_refs = build_exchanges(
        processes, flow_by_uuid, units_by_uuid
    )

    summary = {
        "input_dir": str(input_dir),
        "output_dir": str(output_dir),
        "source_dataset": SOURCE_DATASET,
        "counts": {
            "geographies": len(geographies),
            "categories": len(categories),
            "units": len(units),
            "flows": len(transformed_flows),
            "processes": len(transformed_processes),
            "exchanges": len(transformed_exchanges),
        },
        "unresolved": {
            "flow_default_units": len(unresolved_flow_units),
            "exchange_references": len(unresolved_exchange_refs),
        },
    }

    write_json(output_dir / "geographies.json", geographies)
    write_json(output_dir / "categories.json", categories)
    write_json(output_dir / "units.json", units)
    write_json(output_dir / "flows.json", transformed_flows)
    write_json(output_dir / "processes.json", transformed_processes)
    write_json(output_dir / "exchanges.json", transformed_exchanges)
    write_json(output_dir / "unresolved_flow_units.json", unresolved_flow_units)
    write_json(output_dir / "unresolved_exchange_references.json", unresolved_exchange_refs)
    write_json(output_dir / "summary.json", summary)

    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
