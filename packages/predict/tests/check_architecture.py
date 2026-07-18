#!/usr/bin/env python3
"""Deterministic structural checks for the Predict unit-test architecture."""

from __future__ import annotations

import re
import sys
from pathlib import Path

TESTS = Path(__file__).resolve().parent
REPO = TESTS.parents[2]
SOURCE_ROOTS = tuple(
    REPO / "packages" / package / "sources"
    for package in ("predict", "propbook", "block_scholes_oracle", "account")
)
SCOPES = {"framework", "mechanics", "structure", "flow"}
INTENTS = {"behavior", "guard", "boundary", "rounding", "accounting", "reference", "policy"}
COMMENTS = re.compile(r"//[^\n]*|/\*.*?\*/", re.DOTALL)
ATTRIBUTE_GROUP = re.compile(r"#\s*\[(?P<body>[^]]*)\]", re.DOTALL)
ATTRIBUTED_PUBLIC_FUNCTION = re.compile(
    r"(?P<attributes>(?:#\s*\[[^]]*\]\s*)+)"
    r"public(?:\(package\))?\s+fun\s+(?P<name>[a-z][a-z0-9_]*)",
    re.DOTALL,
)
FOR_TESTING_FUNCTION = re.compile(r"\bfun\s+([a-z][a-z0-9_]*_for_testing)\s*[<(]")
# Exact inventory of pre-existing source seams, not approval to add equivalents.
APPROVED_SOURCE_TEST_SEAMS = {
    "packages/account/sources/account_registry.move": {"init_for_testing"},
    "packages/predict/sources/plp/plp.move": {"init_for_testing"},
    "packages/predict/sources/registry/registry.move": {"init_for_testing"},
    "packages/predict/sources/strike_exposure/index/strike_payout_tree.move": {
        "set_node_count_for_testing"
    },
    "packages/predict/sources/strike_exposure/range_codec.move": {"strike_for_testing"},
    "packages/propbook/sources/feeds/pyth_feed.move": {"record_raw_for_testing"},
    "packages/propbook/sources/registry.move": {"init_for_testing"},
}


def relative(path: Path) -> str:
    return path.relative_to(REPO).as_posix()


def source_without_comments(source: str) -> str:
    return COMMENTS.sub("", source)


def attribute_names(source: str) -> set[str]:
    names = set()
    for group in ATTRIBUTE_GROUP.finditer(source):
        body = group.group("body")
        depth = 0
        start = 0
        for index, character in enumerate(body + ","):
            if character == "(":
                depth += 1
            elif character == ")":
                depth -= 1
            elif character == "," and depth == 0:
                item = body[start:index].strip()
                name = re.match(r"([A-Za-z_][A-Za-z0-9_]*)", item)
                if name:
                    names.add(name.group(1))
                start = index + 1
    return names


def source_test_only_functions(source: str) -> set[str]:
    functions = set()
    for function in ATTRIBUTED_PUBLIC_FUNCTION.finditer(source):
        if "test_only" in attribute_names(function.group("attributes")):
            functions.add(function.group("name"))
    return functions


def source_boundary_errors(source_path: str, text: str) -> list[str]:
    errors = []
    source = source_without_comments(text)
    attributes = attribute_names(source)
    if {"test", "random_test"} & attributes:
        errors.append(
            f"{source_path}: executable unit tests belong under the owning package's tests"
        )
    test_only_functions = source_test_only_functions(source)
    named_test_functions = set(FOR_TESTING_FUNCTION.findall(source))
    approved_seams = APPROVED_SOURCE_TEST_SEAMS.get(source_path, set())
    unapproved_seams = (test_only_functions | named_test_functions) - approved_seams
    for function in sorted(unapproved_seams):
        errors.append(
            f"{source_path}: new source test seam '{function}' requires explicit approval"
        )
    missing_seams = approved_seams - test_only_functions
    for function in sorted(missing_seams):
        errors.append(
            f"{source_path}: approved source test seam '{function}' is missing; update the allowlist"
        )
    test_only_attribute_count = sum(
        "test_only" in attribute_names(group.group(0))
        for group in ATTRIBUTE_GROUP.finditer(source)
    )
    if test_only_attribute_count != len(test_only_functions):
        errors.append(f"{source_path}: unrecognized source #[test_only] declaration")
    return errors


def missing_approved_source_paths(source_paths: set[str]) -> list[str]:
    return sorted(set(APPROVED_SOURCE_TEST_SEAMS) - source_paths)


def scenario_constructor_count(source: str) -> int:
    namespace_aliases = set(
        re.findall(r"\btest_scenario\s+as\s+([a-z][a-z0-9_]*)\b", source)
    )
    function_aliases: set[str] = set()
    for group in re.finditer(r"\btest_scenario\s*::\s*\{(?P<body>[^}]*)\}", source, re.DOTALL):
        body = group.group("body")
        namespace_aliases.update(
            re.findall(r"\bSelf\s+as\s+([a-z][a-z0-9_]*)\b", body)
        )
        for function in re.finditer(
            r"\bbegin\b(?:\s+as\s+([a-z][a-z0-9_]*))?",
            body,
        ):
            function_aliases.add(function.group(1) or "begin")
    for function in re.finditer(
        r"\buse\s+[^;]*\btest_scenario\s*::\s*begin\b"
        r"(?:\s+as\s+([a-z][a-z0-9_]*))?\s*;",
        source,
    ):
        function_aliases.add(function.group(1) or "begin")

    count = len(re.findall(r"\btest_scenario\s*::\s*begin\s*\(", source))
    count += sum(
        len(re.findall(rf"\b{re.escape(alias)}\s*::\s*begin\s*\(", source))
        for alias in namespace_aliases
    )
    count += sum(
        len(re.findall(rf"(?<!::)\b{re.escape(alias)}\s*\(", source))
        for alias in function_aliases
    )
    return count


def accesses_scenario_api(source: str) -> bool:
    if re.search(r"\bScenario\b|\btest_scenario\s*::\s*(?:begin|Self)\b", source):
        return True
    group = re.search(r"\btest_scenario\s*::\s*\{(?P<body>[^}]*)\}", source, re.DOTALL)
    if group and re.search(r"\b(?:begin|Self)\b", group.group("body")):
        return True
    return re.search(r"\btest_scenario\s+as\s+[a-z][a-z0-9_]*\b", source) is not None


def main() -> int:
    errors: list[str] = []
    move_files = sorted(TESTS.rglob("*.move"))
    source_files = sorted(path for root in SOURCE_ROOTS for path in root.rglob("*.move"))
    world_file = TESTS / "framework" / "test_world.move"

    source_paths = {relative(path) for path in source_files}
    for source_path in missing_approved_source_paths(source_paths):
        errors.append(f"{source_path}: approved source test seam file is missing; update the allowlist")
    for path in source_files:
        source_path = relative(path)
        errors.extend(source_boundary_errors(source_path, path.read_text()))

    scenario_fields: list[tuple[Path, int]] = []
    world_constructor_count = 0
    for path in move_files:
        text = path.read_text()
        source = source_without_comments(text)
        field_count = len(re.findall(r":\s*Scenario\b", source))
        if field_count:
            scenario_fields.append((path, field_count))
        if path == world_file:
            world_constructor_count = scenario_constructor_count(source)
        elif accesses_scenario_api(source):
            errors.append(f"{relative(path)}: test_world must own all Scenario API access")
        if path != world_file and re.search(r"\btake_shared\s*<", text):
            errors.append(f"{relative(path)}: ambient take_shared<T> is bootstrap-only")
        if path.parent == TESTS / "framework" and path != world_file:
            if re.search(r"(?:\.|::)next_tx\s*\(", text):
                errors.append(f"{relative(path)}: framework prerequisite hides next_tx")

        if not re.search(r"#\[test(?:\]|,)", text):
            continue
        scope = path.relative_to(TESTS).parts[0]
        if scope not in SCOPES:
            errors.append(f"{relative(path)}: executable module has unknown scope path '{scope}'")
            continue
        module_match = re.search(r"module\s+deepbook_predict::([a-z0-9_]+)\s*;", text)
        if not module_match:
            errors.append(f"{relative(path)}: executable module name is missing or malformed")
            continue
        module = module_match.group(1)
        if not module.startswith(f"{scope}_"):
            errors.append(f"{relative(path)}: module '{module}' does not start with '{scope}_'")
        if not any(f"_{intent}_" in f"_{module}_" for intent in INTENTS):
            errors.append(f"{relative(path)}: module '{module}' has no intent token")

    if scenario_fields != [(world_file, 1)]:
        rendered = ", ".join(
            f"{relative(path)} ({count})" for path, count in scenario_fields
        ) or "none"
        errors.append(
            f"Scenario field owner must be exactly {relative(world_file)} (1); found {rendered}"
        )
    if world_constructor_count != 1:
        errors.append(
            f"{relative(world_file)}: expected exactly one aliased test_scenario::begin constructor; "
            f"found {world_constructor_count}"
        )

    for generated in move_files:
        text = generated.read_text()
        generator_match = re.search(r"^// @generated by (\S+)$", text, re.MULTILINE)
        if not generator_match:
            continue
        generator = REPO / generator_match.group(1)
        if not generator.is_file():
            errors.append(f"{relative(generated)}: generator does not exist: {generator_match.group(1)}")
        if not re.search(r"^// Regenerate: \S+", text, re.MULTILINE):
            errors.append(f"{relative(generated)}: missing regeneration command")
        if not re.search(r"^// Check: \S+", text, re.MULTILINE):
            errors.append(f"{relative(generated)}: missing stale-output check command")

    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        print(f"Predict test architecture: {len(errors)} error(s)")
        return 1
    print(f"Predict test architecture: ok ({len(move_files)} Move files checked)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
