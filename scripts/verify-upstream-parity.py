#!/usr/bin/env python3
import argparse
import re
import sys
from pathlib import Path


ALLOWED_STATUSES = {"ported", "partial", "blocked"}
FORBIDDEN_STATUSES = {"pending"}

# Statuses that must reference at least one Swift test by name. `blocked`
# rows are exempt because the upstream behavior has no Swift coverage yet.
STATUSES_REQUIRING_TESTS = {"ported", "partial"}

TEST_ATTRIBUTE_PATTERN = re.compile(r"@Test\b")
FUNC_NAME_PATTERN = re.compile(r"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)")
IDENTIFIER_PATTERN = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
BACKTICK_PATTERN = re.compile(r"`([^`]+)`")


def markdown_value(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == "`" and value[-1] == "`":
        return value[1:-1]
    return value


def declared_function_names(tests_dir: Path) -> tuple[set[str], set[str]]:
    """Return (@Test function names, all function names) declared in test sources."""
    if not tests_dir.is_dir():
        raise RuntimeError(f"Test directory not found: {tests_dir}")
    swift_files = sorted(tests_dir.rglob("*.swift"))
    if not swift_files:
        raise RuntimeError(f"No Swift test files found under {tests_dir}.")

    test_names: set[str] = set()
    function_names: set[str] = set()
    for file in swift_files:
        text = file.read_text(encoding="utf-8")
        for match in FUNC_NAME_PATTERN.finditer(text):
            function_names.add(match.group(1))
        for attribute in TEST_ATTRIBUTE_PATTERN.finditer(text):
            func_match = FUNC_NAME_PATTERN.search(text, attribute.end())
            if func_match:
                test_names.add(func_match.group(1))
    if not test_names:
        raise RuntimeError(f"No @Test functions found under {tests_dir}.")
    return test_names, function_names


def coverage_test_names(coverage: str) -> list[str]:
    """Extract backticked Swift test names from the leading coverage segment.

    The Swift coverage cell starts with backticked test function names and may
    continue with prose after the first ';'. Only plain identifiers in the
    leading segment are treated as test names; backticked tokens in the prose
    (API names, fixture files, metadata keys) are not.
    """
    leading = coverage.split(";", 1)[0]
    return [
        token
        for token in BACKTICK_PATTERN.findall(leading)
        if IDENTIFIER_PATTERN.fullmatch(token)
    ]


def fixture_patterns(cell: str) -> list[str]:
    """Extract fixture file glob patterns from a backticked fixture cell."""
    patterns: list[str] = []
    for token in BACKTICK_PATTERN.findall(cell):
        for part in token.split(","):
            part = part.strip()
            if part:
                patterns.append(part)
    return patterns


def table_rows(lines: list[str], heading: str) -> list[list[str]]:
    try:
        start = next(index for index, line in enumerate(lines) if line.strip() == heading)
    except StopIteration as error:
        raise RuntimeError(f"Missing heading: {heading}") from error

    rows: list[list[str]] = []
    for line in lines[start + 1:]:
        stripped = line.strip()
        if stripped.startswith("## ") and rows:
            break
        if not stripped.startswith("|"):
            continue
        cells = [cell.strip() for cell in stripped.strip("|").split("|")]
        if all(re.fullmatch(r":?-+:?", cell) for cell in cells):
            continue
        rows.append(cells)
    if len(rows) < 2:
        raise RuntimeError(f"Missing table rows under {heading}.")
    return rows[1:]


def validate_status(status: str, context: str) -> str | None:
    if status in FORBIDDEN_STATUSES:
        return f"{context} is still pending."
    if status not in ALLOWED_STATUSES:
        return f"{context} has invalid status {status!r}."
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify upstream test parity tracking.")
    parser.add_argument(
        "--parity-file",
        default="Tests/OpenUSDTests/UPSTREAM_TEST_PARITY.md",
        help="Markdown file that tracks OpenUSD upstream test parity.",
    )
    parser.add_argument(
        "--tests-dir",
        default="Tests/OpenUSDTests",
        help="Directory containing the Swift test sources and Fixtures/OpenUSD.",
    )
    args = parser.parse_args()

    parity_file = Path(args.parity_file)
    if not parity_file.is_file():
        print(f"Parity file not found: {parity_file}", file=sys.stderr)
        return 2

    tests_dir = Path(args.tests_dir)
    fixtures_root = tests_dir / "Fixtures" / "OpenUSD"
    try:
        test_names, function_names = declared_function_names(tests_dir)
        if not fixtures_root.is_dir():
            raise RuntimeError(f"Fixtures directory not found: {fixtures_root}")
    except RuntimeError as error:
        print(error, file=sys.stderr)
        return 2

    lines = parity_file.read_text(encoding="utf-8").splitlines()
    text = "\n".join(lines)
    errors: list[str] = []

    if not re.search(r"\| Commit \| `[0-9a-f]{40}` \|", text):
        errors.append("Source commit must be recorded as a 40-character hash.")
    if not re.search(r"\| Last verified \| `\d{4}-\d{2}-\d{2}` \|", text):
        errors.append("Last verified date must be recorded as YYYY-MM-DD.")

    try:
        fixture_rows = table_rows(lines, "## Current Upstream Fixtures")
        category_rows = table_rows(lines, "## Next Upstream Categories")
    except RuntimeError as error:
        print(error, file=sys.stderr)
        return 2

    referenced_test_names: set[str] = set()
    checked_fixture_patterns = 0
    for row in fixture_rows:
        if len(row) != 4:
            errors.append(f"Fixture row must have 4 cells: {row}")
            continue
        context = f"Fixture {row[0]} / {row[1]}"
        status = markdown_value(row[2])
        status_error = validate_status(status, context)
        if status_error:
            errors.append(status_error)
        if not row[3] or row[3] == "`-`":
            errors.append(f"{context} is missing Swift coverage.")

        names = coverage_test_names(row[3])
        if status in STATUSES_REQUIRING_TESTS and not names:
            errors.append(
                f"{context} has status `{status}` but references no backticked "
                "Swift test name before the first ';' in its coverage cell."
            )
        for name in names:
            referenced_test_names.add(name)
            if name in test_names:
                continue
            if name in function_names:
                errors.append(
                    f"{context} references `{name}`, which exists but is not a @Test function."
                )
            else:
                errors.append(f"{context} references missing Swift test `{name}`.")

        testenv_name = markdown_value(row[0]).rstrip("/").split("/")[-1]
        testenv_dir = fixtures_root / testenv_name
        if not testenv_dir.is_dir():
            errors.append(f"{context} has no fixture directory at {testenv_dir}.")
            continue
        patterns = fixture_patterns(row[1])
        if not patterns:
            errors.append(f"{context} lists no backticked fixture file names.")
        for pattern in patterns:
            checked_fixture_patterns += 1
            if not any(testenv_dir.glob(pattern)):
                errors.append(f"{context} references missing fixture {testenv_dir / pattern}.")

    for row in category_rows:
        if len(row) != 4:
            errors.append(f"Category row must have 4 cells: {row}")
            continue
        status_error = validate_status(markdown_value(row[2]), f"Category {row[1]}")
        if status_error:
            errors.append(status_error)
        if not row[3]:
            errors.append(f"Category {row[1]} is missing a next action.")

    if errors:
        print("Upstream parity tracking failed:", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1

    print(
        f"Verified {len(fixture_rows)} upstream fixture rows, {len(category_rows)} categories, "
        f"{len(referenced_test_names)} referenced Swift tests, and "
        f"{checked_fixture_patterns} fixture file patterns."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
