"""Inspect an ILCD export directory before building the full parser.

The goal of this script is to answer a few practical questions early:

- Does the export directory actually contain XML files?
- Which folders are present, and how many XML files are in each?
- Do the filenames or XML roots suggest process, flow, unit, or source data?
- Can we extract a few identifying metadata fields from sample files?

This helps stabilize the next pipeline step (`parse_ilcd.py`) around the
real export structure instead of assumptions.
"""

from __future__ import annotations

import argparse
import json
from collections import Counter
from dataclasses import asdict, dataclass
from pathlib import Path
import sys
import xml.etree.ElementTree as ET


DEFAULT_EXPORT_DIR = Path("data/raw/elcd_3_2/exported/ilcd")
SAMPLE_LIMIT = 3


@dataclass
class SampleFile:
    path: str
    root_tag: str
    inferred_kind: str
    uuid: str | None
    version: str | None
    name: str | None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Inspect an ILCD export directory and summarize its contents."
    )
    parser.add_argument(
        "export_dir",
        nargs="?",
        default=str(DEFAULT_EXPORT_DIR),
        help=(
            "Path to the ILCD export directory. "
            f"Defaults to {DEFAULT_EXPORT_DIR}."
        ),
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit the summary as JSON instead of plain text.",
    )
    parser.add_argument(
        "--samples-per-kind",
        type=int,
        default=SAMPLE_LIMIT,
        help=f"Number of sample XML files to show per inferred kind. Default: {SAMPLE_LIMIT}.",
    )
    return parser.parse_args()


def strip_namespace(tag: str) -> str:
    if "}" in tag:
        return tag.rsplit("}", 1)[1]
    return tag


def find_first_text(root: ET.Element, candidates: list[str]) -> str | None:
    for element in root.iter():
        tag = strip_namespace(element.tag).lower()
        if tag in candidates:
            text = (element.text or "").strip()
            if text:
                return text
    return None


def infer_kind(path: Path, root_tag: str) -> str:
    joined_parts = "/".join(part.lower() for part in path.parts)
    root_lower = root_tag.lower()

    kind_hints = {
        "process": ["process", "activitydataset"],
        "flow": ["flow", "flowdataset"],
        "unit": ["unit", "unitgroup", "unitdataset"],
        "source": ["source", "sourcedataset"],
        "contact": ["contact", "contactdataset"],
        "category": ["category", "classification"],
    }

    for kind, hints in kind_hints.items():
        if any(hint in joined_parts or hint in root_lower for hint in hints):
            return kind
    return "unknown"


def parse_sample(xml_path: Path, base_dir: Path) -> SampleFile:
    tree = ET.parse(xml_path)
    root = tree.getroot()
    root_tag = strip_namespace(root.tag)
    inferred_kind = infer_kind(xml_path.relative_to(base_dir), root_tag)

    uuid = find_first_text(root, ["uuid", "id"])
    version = find_first_text(root, ["version", "dataSetVersion"])
    name = find_first_text(
        root,
        [
            "name",
            "baseName",
            "shortname",
            "commonname",
            "referenceToName",
        ],
    )

    return SampleFile(
        path=str(xml_path.relative_to(base_dir)),
        root_tag=root_tag,
        inferred_kind=inferred_kind,
        uuid=uuid,
        version=version,
        name=name,
    )


def collect_summary(export_dir: Path, samples_per_kind: int) -> dict:
    if not export_dir.exists():
        raise FileNotFoundError(
            f"Export directory does not exist: {export_dir}"
        )
    if not export_dir.is_dir():
        raise NotADirectoryError(
            f"Export path is not a directory: {export_dir}"
        )

    xml_files = sorted(export_dir.rglob("*.xml"))
    xml_counts_by_folder: Counter[str] = Counter()
    sample_groups: dict[str, list[SampleFile]] = {}
    parse_errors: list[dict[str, str]] = []
    root_tag_counts: Counter[str] = Counter()

    # Walk the export once and collect a compact inventory we can use to
    # decide how the real parser should be shaped.
    for xml_path in xml_files:
        relative_parent = (
            str(xml_path.parent.relative_to(export_dir))
            if xml_path.parent != export_dir
            else "."
        )
        xml_counts_by_folder[relative_parent] += 1

        try:
            sample = parse_sample(xml_path, export_dir)
        except ET.ParseError as exc:
            parse_errors.append(
                {
                    "path": str(xml_path.relative_to(export_dir)),
                    "error": str(exc),
                }
            )
            continue

        root_tag_counts[sample.root_tag] += 1
        group = sample_groups.setdefault(sample.inferred_kind, [])
        if len(group) < samples_per_kind:
            group.append(sample)

    inferred_kind_counts = Counter()
    for samples in sample_groups.values():
        for sample in samples:
            inferred_kind_counts[sample.inferred_kind] += 1

    return {
        "export_dir": str(export_dir),
        "exists": True,
        "xml_file_count": len(xml_files),
        "folder_count": len(
            [
                path
                for path in export_dir.rglob("*")
                if path.is_dir()
            ]
        ),
        "xml_counts_by_folder": dict(sorted(xml_counts_by_folder.items())),
        "root_tag_counts": dict(root_tag_counts.most_common()),
        "sample_files_by_kind": {
            kind: [asdict(sample) for sample in samples]
            for kind, samples in sorted(sample_groups.items())
        },
        "sampled_kind_count": dict(sorted(inferred_kind_counts.items())),
        "parse_errors": parse_errors,
    }


def render_text(summary: dict) -> str:
    lines: list[str] = []
    lines.append(f"ILCD export directory: {summary['export_dir']}")
    lines.append(f"XML files found: {summary['xml_file_count']}")
    lines.append(f"Subdirectories found: {summary['folder_count']}")

    if summary["xml_file_count"] == 0:
        lines.append("")
        lines.append(
            "No XML files found. Export the ELCD dataset from openLCA into this "
            "directory before moving on to parse_ilcd.py."
        )
        return "\n".join(lines)

    lines.append("")
    lines.append("XML files by folder:")
    for folder, count in summary["xml_counts_by_folder"].items():
        lines.append(f"  - {folder}: {count}")

    if summary["root_tag_counts"]:
        lines.append("")
        lines.append("Root tags:")
        for root_tag, count in summary["root_tag_counts"].items():
            lines.append(f"  - {root_tag}: {count}")

    if summary["sample_files_by_kind"]:
        lines.append("")
        lines.append("Sample files by inferred kind:")
        for kind, samples in summary["sample_files_by_kind"].items():
            lines.append(f"  - {kind}:")
            for sample in samples:
                name = sample["name"] or "n/a"
                uuid = sample["uuid"] or "n/a"
                version = sample["version"] or "n/a"
                lines.append(
                    f"    {sample['path']} | root={sample['root_tag']} | "
                    f"name={name} | uuid={uuid} | version={version}"
                )

    if summary["parse_errors"]:
        lines.append("")
        lines.append("Parse errors:")
        for error in summary["parse_errors"]:
            lines.append(f"  - {error['path']}: {error['error']}")

    return "\n".join(lines)


def main() -> int:
    args = parse_args()
    export_dir = Path(args.export_dir).expanduser().resolve()

    try:
        summary = collect_summary(export_dir, args.samples_per_kind)
    except (FileNotFoundError, NotADirectoryError) as exc:
        print(str(exc), file=sys.stderr)
        return 1

    # Keep the CLI flexible: human-readable output for inspection, JSON for
    # piping into later tooling if needed.
    if args.json:
        print(json.dumps(summary, indent=2))
    else:
        print(render_text(summary))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
