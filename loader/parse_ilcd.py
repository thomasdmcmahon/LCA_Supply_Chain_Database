"""Parse exported ILCD XML into normalized JSON files.

This is the first real parser pass for the ELCD export. It intentionally
stops short of loading data into PostgreSQL. Instead, it extracts the stable
metadata and exchange links we need in order to design the transformation and
loading stages around the real ILCD structure.
"""

from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path
from typing import Any
import xml.etree.ElementTree as ET


DEFAULT_INPUT_DIR = Path("data/raw/elcd_3_2/exported/ilcd/ILCD")
DEFAULT_OUTPUT_DIR = Path("data/processed/elcd_3_2")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Parse ILCD export XML into normalized JSON artifacts."
    )
    parser.add_argument(
        "input_dir",
        nargs="?",
        default=str(DEFAULT_INPUT_DIR),
        help=f"ILCD export directory. Defaults to {DEFAULT_INPUT_DIR}.",
    )
    parser.add_argument(
        "--output-dir",
        default=str(DEFAULT_OUTPUT_DIR),
        help=f"Directory for processed JSON output. Defaults to {DEFAULT_OUTPUT_DIR}.",
    )
    return parser.parse_args()


def local_name(tag: str) -> str:
    if "}" in tag:
        return tag.rsplit("}", 1)[1]
    return tag


def element_text(element: ET.Element | None) -> str | None:
    if element is None or element.text is None:
        return None
    text = element.text.strip()
    return text or None


def find_child(element: ET.Element, tag_name: str) -> ET.Element | None:
    for child in element:
        if local_name(child.tag) == tag_name:
            return child
    return None


def find_children(element: ET.Element, tag_name: str) -> list[ET.Element]:
    return [child for child in element if local_name(child.tag) == tag_name]


def first_descendant_text(element: ET.Element, names: list[str]) -> str | None:
    wanted = set(names)
    for descendant in element.iter():
        if local_name(descendant.tag) in wanted:
            text = element_text(descendant)
            if text:
                return text
    return None


def parse_float(text: str | None) -> float | None:
    if text is None:
        return None
    try:
        return float(text)
    except ValueError:
        return None


def parse_process(path: Path) -> dict[str, Any]:
    root = ET.parse(path).getroot()

    process_information = find_child(root, "processInformation")
    exchanges_parent = find_child(root, "exchanges")
    if process_information is None:
        raise ValueError(f"Missing processInformation in {path}")

    data_set_information = find_child(process_information, "dataSetInformation")
    quantitative_reference = find_child(process_information, "quantitativeReference")
    time_info = find_child(process_information, "time")
    geography = find_child(process_information, "geography")
    technology = find_child(process_information, "technology")

    reference_flow_ids = {
        element_text(ref)
        for ref in (find_children(quantitative_reference, "referenceToReferenceFlow") if quantitative_reference is not None else [])
        if element_text(ref)
    }

    classifications: list[dict[str, Any]] = []
    if data_set_information is not None:
        class_info = find_child(data_set_information, "classificationInformation")
        if class_info is not None:
            classification = find_child(class_info, "classification")
            if classification is None:
                classification = find_child(class_info, "elementaryFlowCategorization")
            if classification is not None:
                for class_element in classification:
                    if local_name(class_element.tag) not in {"class", "category"}:
                        continue
                    classifications.append(
                        {
                            "level": class_element.attrib.get("level"),
                            "id": class_element.attrib.get("classId") or class_element.attrib.get("catId"),
                            "name": element_text(class_element),
                        }
                    )

    # Processes are the most important ILCD records for the relational model,
    # so we keep both the process metadata and the raw exchange links together.
    exchanges: list[dict[str, Any]] = []
    exchange_direction_counts: Counter[str] = Counter()
    if exchanges_parent is not None:
        for exchange in find_children(exchanges_parent, "exchange"):
            flow_ref = find_child(exchange, "referenceToFlowDataSet")
            direction = element_text(find_child(exchange, "exchangeDirection"))
            normalized_direction = direction.lower() if direction else None
            if normalized_direction:
                exchange_direction_counts[normalized_direction] += 1

            internal_id = exchange.attrib.get("dataSetInternalID")
            amount_text = (
                exchange.attrib.get("{http://openlca.org/ilcd-extensions}amount")
                or element_text(find_child(exchange, "resultingAmount"))
                or element_text(find_child(exchange, "meanAmount"))
            )
            exchanges.append(
                {
                    "internal_id": internal_id,
                    "is_reference_flow": internal_id in reference_flow_ids,
                    "flow_uuid": None if flow_ref is None else flow_ref.attrib.get("refObjectId"),
                    "flow_name": first_descendant_text(flow_ref, ["shortDescription"]) if flow_ref is not None else None,
                    "direction": normalized_direction,
                    "mean_amount": parse_float(element_text(find_child(exchange, "meanAmount"))),
                    "resulting_amount": parse_float(element_text(find_child(exchange, "resultingAmount"))),
                    "amount": parse_float(amount_text),
                    "unit_uuid": exchange.attrib.get("{http://openlca.org/ilcd-extensions}unitId"),
                    "property_uuid": exchange.attrib.get("{http://openlca.org/ilcd-extensions}propertyId"),
                }
            )

    administrative_information = find_child(root, "administrativeInformation")
    publication = (
        None
        if administrative_information is None
        else find_child(administrative_information, "publicationAndOwnership")
    )

    location_element = None if geography is None else find_child(geography, "locationOfOperationSupplyOrProduction")

    return {
        "uuid": first_descendant_text(data_set_information, ["UUID"]) if data_set_information is not None else None,
        "name": first_descendant_text(data_set_information, ["baseName", "name"]),
        "version": first_descendant_text(publication, ["dataSetVersion"]) if publication is not None else None,
        "reference_year": first_descendant_text(time_info, ["referenceYear"]) if time_info is not None else None,
        "valid_until": first_descendant_text(time_info, ["dataSetValidUntil"]) if time_info is not None else None,
        "geography_code": None if location_element is None else location_element.attrib.get("location"),
        "technology_description": first_descendant_text(
            technology, ["technologyDescriptionAndIncludedProcesses"]
        ) if technology is not None else None,
        "classifications": classifications,
        "reference_flow_internal_ids": sorted(reference_flow_ids),
        "exchange_count": len(exchanges),
        "exchange_direction_counts": dict(exchange_direction_counts),
        "exchanges": exchanges,
        "source_file": str(path),
    }


def parse_flow(path: Path) -> dict[str, Any]:
    root = ET.parse(path).getroot()
    flow_information = find_child(root, "flowInformation")
    if flow_information is None:
        raise ValueError(f"Missing flowInformation in {path}")

    data_set_information = find_child(flow_information, "dataSetInformation")
    quantitative_reference = find_child(flow_information, "quantitativeReference")
    administrative_information = find_child(root, "administrativeInformation")
    publication = (
        None
        if administrative_information is None
        else find_child(administrative_information, "publicationAndOwnership")
    )

    classifications: list[dict[str, Any]] = []
    if data_set_information is not None:
        class_info = find_child(data_set_information, "classificationInformation")
        if class_info is not None:
            classification = find_child(class_info, "classification")
            if classification is None:
                classification = find_child(class_info, "elementaryFlowCategorization")
            if classification is not None:
                for class_element in classification:
                    if local_name(class_element.tag) not in {"class", "category"}:
                        continue
                    classifications.append(
                        {
                            "level": class_element.attrib.get("level"),
                            "id": class_element.attrib.get("classId") or class_element.attrib.get("catId"),
                            "name": element_text(class_element),
                        }
                    )

    # Flow properties tell us how a flow is measured and later help connect
    # each flow to a default unit in the transform step.
    flow_properties_parent = find_child(root, "flowProperties")
    flow_properties: list[dict[str, Any]] = []
    if flow_properties_parent is not None:
        for flow_property in find_children(flow_properties_parent, "flowProperty"):
            ref = find_child(flow_property, "referenceToFlowPropertyDataSet")
            flow_properties.append(
                {
                    "internal_id": flow_property.attrib.get("dataSetInternalID"),
                    "flow_property_uuid": None if ref is None else ref.attrib.get("refObjectId"),
                    "flow_property_name": first_descendant_text(ref, ["shortDescription"]) if ref is not None else None,
                    "mean_value": parse_float(element_text(find_child(flow_property, "meanValue"))),
                }
            )

    return {
        "uuid": first_descendant_text(data_set_information, ["UUID"]) if data_set_information is not None else None,
        "name": first_descendant_text(data_set_information, ["baseName", "name"]),
        "version": first_descendant_text(publication, ["dataSetVersion"]) if publication is not None else None,
        "dataset_type": first_descendant_text(root, ["typeOfDataSet"]),
        "cas_number": first_descendant_text(data_set_information, ["CASNumber"]) if data_set_information is not None else None,
        "classifications": classifications,
        "reference_flow_property_internal_id": (
            first_descendant_text(quantitative_reference, ["referenceToReferenceFlowProperty"])
            if quantitative_reference is not None
            else None
        ),
        "flow_properties": flow_properties,
        "source_file": str(path),
    }


def parse_flow_property(path: Path) -> dict[str, Any]:
    root = ET.parse(path).getroot()
    info = find_child(root, "flowPropertiesInformation")
    if info is None:
        raise ValueError(f"Missing flowPropertiesInformation in {path}")

    data_set_information = find_child(info, "dataSetInformation")
    quantitative_reference = find_child(info, "quantitativeReference")
    administrative_information = find_child(root, "administrativeInformation")
    publication = (
        None
        if administrative_information is None
        else find_child(administrative_information, "publicationAndOwnership")
    )
    ref_group = (
        None
        if quantitative_reference is None
        else find_child(quantitative_reference, "referenceToReferenceUnitGroup")
    )

    return {
        "uuid": first_descendant_text(data_set_information, ["UUID"]) if data_set_information is not None else None,
        "name": first_descendant_text(data_set_information, ["name"]),
        "version": first_descendant_text(publication, ["dataSetVersion"]) if publication is not None else None,
        "reference_unit_group_uuid": None if ref_group is None else ref_group.attrib.get("refObjectId"),
        "reference_unit_group_name": first_descendant_text(ref_group, ["shortDescription"]) if ref_group is not None else None,
        "source_file": str(path),
    }


def parse_unit_group(path: Path) -> dict[str, Any]:
    root = ET.parse(path).getroot()
    info = find_child(root, "unitGroupInformation")
    if info is None:
        raise ValueError(f"Missing unitGroupInformation in {path}")

    data_set_information = find_child(info, "dataSetInformation")
    quantitative_reference = find_child(info, "quantitativeReference")
    administrative_information = find_child(root, "administrativeInformation")
    publication = (
        None
        if administrative_information is None
        else find_child(administrative_information, "publicationAndOwnership")
    )

    units_parent = find_child(root, "units")
    units: list[dict[str, Any]] = []
    if units_parent is not None:
        for unit in find_children(units_parent, "unit"):
            units.append(
                {
                    "internal_id": unit.attrib.get("dataSetInternalID"),
                    "uuid": unit.attrib.get("{http://openlca.org/ilcd-extensions}unitId"),
                    "name": first_descendant_text(unit, ["name"]),
                    "mean_value": parse_float(first_descendant_text(unit, ["meanValue"])),
                }
            )

    return {
        "uuid": first_descendant_text(data_set_information, ["UUID"]) if data_set_information is not None else None,
        "name": first_descendant_text(data_set_information, ["name"]),
        "version": first_descendant_text(publication, ["dataSetVersion"]) if publication is not None else None,
        "reference_unit_internal_id": (
            first_descendant_text(quantitative_reference, ["referenceToReferenceUnit"])
            if quantitative_reference is not None
            else None
        ),
        "unit_count": len(units),
        "units": units,
        "source_file": str(path),
    }


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")


def main() -> int:
    args = parse_args()
    input_dir = Path(args.input_dir).expanduser().resolve()
    output_dir = Path(args.output_dir).expanduser().resolve()

    if not input_dir.exists() or not input_dir.is_dir():
        raise SystemExit(f"Input directory does not exist or is not a directory: {input_dir}")

    # Parse each ILCD record family into a lighter JSON form before we do any
    # schema-specific reshaping.
    processes = [
        parse_process(path)
        for path in sorted((input_dir / "processes").glob("*.xml"))
    ]
    flows = [
        parse_flow(path)
        for path in sorted((input_dir / "flows").glob("*.xml"))
    ]
    flow_properties = [
        parse_flow_property(path)
        for path in sorted((input_dir / "flowproperties").glob("*.xml"))
    ]
    unit_groups = [
        parse_unit_group(path)
        for path in sorted((input_dir / "unitgroups").glob("*.xml"))
    ]

    summary = {
        "input_dir": str(input_dir),
        "output_dir": str(output_dir),
        "counts": {
            "processes": len(processes),
            "flows": len(flows),
            "flow_properties": len(flow_properties),
            "unit_groups": len(unit_groups),
            "process_exchanges": sum(process["exchange_count"] for process in processes),
        },
        "process_names": [process["name"] for process in processes],
    }

    write_json(output_dir / "processes.json", processes)
    write_json(output_dir / "flows.json", flows)
    write_json(output_dir / "flow_properties.json", flow_properties)
    write_json(output_dir / "unit_groups.json", unit_groups)
    write_json(output_dir / "summary.json", summary)

    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
