#!/usr/bin/env python3
import argparse
import json
import sys
from collections import Counter
from pathlib import Path


UNSUPPORTED_FEATURE_CALL = "USDError.unsupportedFeature("


def call_argument(text: str, start: int) -> str:
    index = start + len(UNSUPPORTED_FEATURE_CALL)
    depth = 1
    in_string = False
    escaped = False
    while index < len(text):
        character = text[index]
        if in_string:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_string = False
        else:
            if character == '"':
                in_string = True
            elif character == "(":
                depth += 1
            elif character == ")":
                depth -= 1
                if depth == 0:
                    return text[start + len(UNSUPPORTED_FEATURE_CALL):index]
        index += 1
    raise RuntimeError("Unterminated unsupportedFeature call.")


def skip_interpolation(argument: str, index: int) -> int:
    depth = 1
    in_string = False
    escaped = False
    while index < len(argument) and depth:
        character = argument[index]
        if in_string:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_string = False
        else:
            if character == '"':
                in_string = True
            elif character == "(":
                depth += 1
            elif character == ")":
                depth -= 1
        index += 1
    return index


def normalized_string_pattern(argument: str) -> str:
    pieces: list[str] = []
    index = 0
    while index < len(argument):
        if argument[index] != '"':
            index += 1
            continue
        index += 1
        piece: list[str] = []
        while index < len(argument):
            character = argument[index]
            if character == '"':
                index += 1
                break
            if character == "\\" and index + 1 < len(argument):
                next_character = argument[index + 1]
                if next_character == "(":
                    piece.append("<value>")
                    index = skip_interpolation(argument, index + 2)
                    continue
                piece.append("\\" + next_character)
                index += 2
                continue
            piece.append(character)
            index += 1
        pieces.append("".join(piece))
    return " ".join(" ".join(pieces).split())


def current_records(source_dir: Path) -> list[dict[str, str]]:
    if not source_dir.is_dir():
        raise RuntimeError(f"Source directory not found: {source_dir}")
    swift_files = sorted(source_dir.rglob("*.swift"))
    if not swift_files:
        raise RuntimeError(f"No Swift source files found under {source_dir}.")

    records: list[dict[str, str]] = []
    for file in swift_files:
        text = file.read_text(encoding="utf-8")
        cursor = 0
        while True:
            start = text.find(UNSUPPORTED_FEATURE_CALL, cursor)
            if start < 0:
                break
            argument = call_argument(text, start)
            records.append(
                {
                    "file": str(file),
                    "pattern": normalized_string_pattern(argument),
                }
            )
            cursor = start + len(UNSUPPORTED_FEATURE_CALL)
    return records


def inventory_records(inventory_file: Path) -> list[dict[str, str]]:
    if not inventory_file.is_file():
        raise RuntimeError(f"Inventory file not found: {inventory_file}")
    with inventory_file.open(encoding="utf-8") as handle:
        records = json.load(handle)
    if not isinstance(records, list):
        raise RuntimeError("Unsupported feature inventory must be a JSON array.")
    for index, record in enumerate(records):
        if not isinstance(record, dict):
            raise RuntimeError(f"Inventory record {index} must be an object.")
        for key in ("file", "pattern", "category", "resolution"):
            value = record.get(key)
            if not isinstance(value, str) or not value:
                raise RuntimeError(f"Inventory record {index} is missing a non-empty {key}.")
    return records


def key(record: dict[str, str]) -> tuple[str, str]:
    return (record["file"], record["pattern"])


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify the unsupported feature inventory.")
    parser.add_argument("--source-dir", default="Sources", help="Swift source directory to scan.")
    parser.add_argument(
        "--inventory",
        default="Tests/OpenUSDTests/UNSUPPORTED_FEATURES.json",
        help="JSON inventory of expected unsupportedFeature call sites.",
    )
    args = parser.parse_args()

    try:
        current = current_records(Path(args.source_dir))
        inventory = inventory_records(Path(args.inventory))
    except RuntimeError as error:
        print(error, file=sys.stderr)
        return 2

    current_counter = Counter(key(record) for record in current)
    inventory_counter = Counter(key(record) for record in inventory)
    untracked = current_counter - inventory_counter
    obsolete = inventory_counter - current_counter

    if untracked:
        print("Untracked unsupportedFeature call sites:", file=sys.stderr)
        for file, pattern in sorted(untracked):
            print(f"  - {file}: {pattern}", file=sys.stderr)
    if obsolete:
        print("Obsolete unsupportedFeature inventory entries:", file=sys.stderr)
        for file, pattern in sorted(obsolete):
            print(f"  - {file}: {pattern}", file=sys.stderr)
    if untracked or obsolete:
        return 1

    print(f"Verified {len(current)} unsupportedFeature call sites.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
