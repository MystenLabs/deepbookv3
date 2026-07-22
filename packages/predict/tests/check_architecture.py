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
TAXONOMY = re.compile(
    r"^scope_(?P<scope>framework|mechanics|structure|flow)__"
    r"intent_(?P<intent>behavior|guard|boundary|rounding|accounting|reference|policy)__"
    r"(?P<subject>[a-z][a-z0-9_]*)_tests$"
)
RESERVED_TAXONOMY_MARKER = re.compile(
    r"(?:scope_(?:framework|mechanics|structure|flow)__|"
    r"intent_(?:behavior|guard|boundary|rounding|accounting|reference|policy)__)")
DIRECT_ASSERTION = re.compile(r"\bassert(?:_eq)?\s*!")
ASSERTION_CALL = re.compile(r"\bassert(?P<eq>_eq)?\s*!\s*\(")
# A bare identifier or integer literal; anything containing ( . :: [ or an
# operator fails the fullmatch and is exempt from the vacuity check.
ATOMIC_OPERAND = re.compile(r"[A-Za-z_][A-Za-z0-9_]*|\d[\dA-Za-z_]*")
SCENARIO_PROGRESSION_FUNCTIONS = {
    "next_tx",
    "next_with_context",
    "next_epoch",
    "later_epoch",
    "skip_to_epoch",
}
WORLD_PROGRESSION_FUNCTIONS = {"next_tx", "next_tx_with_epoch", "next_tx_with_gas_price"}
PROGRESSION_FUNCTION_PATTERN = "|".join(
    sorted(SCENARIO_PROGRESSION_FUNCTIONS | WORLD_PROGRESSION_FUNCTIONS)
)
TRANSACTION_PROGRESSION = re.compile(
    rf"(?:\.|::)(?:{PROGRESSION_FUNCTION_PATTERN})\s*\("
)
OWNED_RESOURCES = re.compile(
    r"public\s+struct\s+OwnedResources\s*\{(?P<body>[^}]*)\}",
    re.DOTALL,
)
APPROVED_WORLD_PROGRESSION_FUNCTIONS = {
    "new",
    "next_tx",
    "next_tx_with_epoch",
    "next_tx_with_gas_price",
}
SCENARIO_CONSTRUCTORS = {"begin", "begin_with_context"}
ATTRIBUTE_GROUP = re.compile(r"#\s*\[(?P<body>[^]]*)\]", re.DOTALL)
ATTRIBUTED_PUBLIC_FUNCTION = re.compile(
    r"(?P<attributes>(?:#\s*\[[^]]*\]\s*)+)"
    r"public(?:\(package\))?\s+(?:entry\s+)?fun\s+(?P<name>[a-z][a-z0-9_]*)",
    re.DOTALL,
)
ATTRIBUTED_FUNCTION = re.compile(
    r"(?P<attributes>(?:#\s*\[[^]]*\]\s*)+)"
    r"(?:public(?:\(package\))?\s+)?(?:entry\s+)?fun\s+(?P<name>[a-z][a-z0-9_]*)",
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
    """Mask comments and string literals while preserving source positions."""
    masked = list(source)
    index = 0
    while index < len(source):
        if source[index] == '"':
            masked[index] = " "
            index += 1
            while index < len(source):
                character = source[index]
                if character != "\n":
                    masked[index] = " "
                index += 1
                if character == "\\" and index < len(source):
                    if source[index] != "\n":
                        masked[index] = " "
                    index += 1
                elif character == '"':
                    break
            continue
        if source.startswith("//", index):
            while index < len(source) and source[index] != "\n":
                masked[index] = " "
                index += 1
            continue
        if source.startswith("/*", index):
            depth = 1
            masked[index:index + 2] = [" ", " "]
            index += 2
            while index < len(source) and depth:
                if source.startswith("/*", index):
                    depth += 1
                    masked[index:index + 2] = [" ", " "]
                    index += 2
                elif source.startswith("*/", index):
                    depth -= 1
                    masked[index:index + 2] = [" ", " "]
                    index += 2
                else:
                    if source[index] != "\n":
                        masked[index] = " "
                    index += 1
            continue
        index += 1
    return "".join(masked)


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
    constructor_pattern = "|".join(sorted(SCENARIO_CONSTRUCTORS))
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
            rf"\b(?P<function>{constructor_pattern})\b"
            r"(?:\s+as\s+(?P<alias>[a-z][a-z0-9_]*))?",
            body,
        ):
            function_aliases.add(function.group("alias") or function.group("function"))
    for function in re.finditer(
        rf"\buse\s+[^;]*\btest_scenario\s*::\s*"
        rf"(?P<function>{constructor_pattern})\b"
        r"(?:\s+as\s+(?P<alias>[a-z][a-z0-9_]*))?\s*;",
        source,
    ):
        function_aliases.add(function.group("alias") or function.group("function"))

    count = len(
        re.findall(
            rf"\btest_scenario\s*::\s*(?:{constructor_pattern})\s*\(",
            source,
        )
    )
    count += sum(
        len(
            re.findall(
                rf"\b{re.escape(alias)}\s*::\s*"
                rf"(?:{constructor_pattern})\s*\(",
                source,
            )
        )
        for alias in namespace_aliases
    )
    count += sum(
        len(re.findall(rf"(?<!::)\b{re.escape(alias)}\s*\(", source))
        for alias in function_aliases
    )
    return count


def accesses_scenario_api(source: str) -> bool:
    if re.search(
        r"\bScenario\b|\btest_scenario\s*::\s*"
        r"(?:begin|begin_with_context|Self)\b",
        source,
    ):
        return True
    for group in re.finditer(
        r"\btest_scenario\s*::\s*\{(?P<body>[^}]*)\}", source, re.DOTALL
    ):
        if re.search(r"\b(?:begin|begin_with_context|Self)\b", group.group("body")):
            return True
    return re.search(r"\btest_scenario\s+as\s+[a-z][a-z0-9_]*\b", source) is not None


def has_executable_test(source: str) -> bool:
    return bool({"test", "random_test"} & attribute_names(source))


def scenario_field_count(source: str) -> int:
    return len(re.findall(r":\s*Scenario\b", source))


def attributed_test_records(source: str) -> list[tuple[str, set[str], str, int, int]]:
    functions = []
    for function in ATTRIBUTED_FUNCTION.finditer(source):
        attributes = attribute_names(function.group("attributes"))
        if not ({"test", "random_test"} & attributes):
            continue
        body_start = source.find("{", function.end())
        if body_start < 0:
            continue
        depth = 0
        for index in range(body_start, len(source)):
            if source[index] == "{":
                depth += 1
            elif source[index] == "}":
                depth -= 1
                if depth == 0:
                    functions.append((
                        function.group("name"),
                        attributes,
                        source[body_start + 1:index],
                        body_start,
                        index + 1,
                    ))
                    break
    return functions


def attributed_test_spans(source: str) -> list[tuple[str, str, int, int]]:
    return [
        (name, body, start, end)
        for name, _, body, start, end in attributed_test_records(source)
    ]


def attributed_test_bodies(source: str) -> list[tuple[str, str]]:
    return [(name, body) for name, body, _, _ in attributed_test_spans(source)]


def source_outside_test_bodies(source: str) -> str:
    outside = list(source)
    for _, _, start, end in attributed_test_spans(source):
        outside[start:end] = " " * (end - start)
    return "".join(outside)


def hidden_transaction_progression_errors(source_path: str, text: str) -> list[str]:
    source = source_without_comments(text)
    outside_tests = source_outside_test_bodies(source)
    function_aliases = progression_function_aliases(
        source,
        {"test_world", "test_scenario"},
        SCENARIO_PROGRESSION_FUNCTIONS | WORLD_PROGRESSION_FUNCTIONS,
    )
    aliased_progression = any(
        re.search(rf"(?<!::)(?<!\.)\b{re.escape(alias)}\s*\(", outside_tests)
        for alias in function_aliases
    )
    if TRANSACTION_PROGRESSION.search(outside_tests) or aliased_progression:
        return [f"{source_path}: prerequisite helper hides transaction progression"]
    return []


def progression_function_aliases(
    source: str,
    modules: set[str],
    functions: set[str],
) -> set[str]:
    module_pattern = "|".join(sorted(re.escape(module) for module in modules))
    function_pattern = "|".join(sorted(re.escape(function) for function in functions))
    aliases: set[str] = set()
    for function in re.finditer(
        rf"\b(?:{module_pattern})\s*::\s*"
        rf"(?P<function>{function_pattern})\b"
        r"(?:\s+as\s+(?P<alias>[a-z][a-z0-9_]*))?\s*;",
        source,
    ):
        aliases.add(function.group("alias") or function.group("function"))
    for group in re.finditer(
        rf"\b(?:{module_pattern})\s*::\s*\{{(?P<body>[^}}]*)\}}",
        source,
        re.DOTALL,
    ):
        for function in re.finditer(
            rf"\b(?P<function>{function_pattern})\b"
            r"(?:\s+as\s+(?P<alias>[a-z][a-z0-9_]*))?",
            group.group("body"),
        ):
            aliases.add(function.group("alias") or function.group("function"))
    return aliases


def owned_resources_capability_errors(source_path: str, text: str) -> list[str]:
    source = source_without_comments(text)
    resource_struct = OWNED_RESOURCES.search(source)
    if not resource_struct:
        return [f"{source_path}: OwnedResources declaration is missing"]
    body = re.sub(r"\s+", "", resource_struct.group("body")).strip(",")
    if body != "clock:Clock":
        return [f"{source_path}: OwnedResources must be exactly {{ clock: Clock }}"]
    return []


def function_bodies(source: str) -> dict[str, str]:
    functions: dict[str, str] = {}
    for function in re.finditer(
        r"\b(?:public(?:\(package\))?\s+)?(?:entry\s+)?fun\s+"
        r"(?P<name>[a-z][a-z0-9_]*)\b",
        source,
    ):
        body_start = source.find("{", function.end())
        if body_start < 0:
            continue
        depth = 0
        for index in range(body_start, len(source)):
            if source[index] == "{":
                depth += 1
            elif source[index] == "}":
                depth -= 1
                if depth == 0:
                    functions[function.group("name")] = source[body_start + 1:index]
                    break
    return functions


def world_progression_api_errors(source_path: str, text: str) -> list[str]:
    source = source_without_comments(text)
    functions = function_bodies(source)
    aliases = progression_function_aliases(
        source,
        {"test_scenario"},
        SCENARIO_PROGRESSION_FUNCTIONS,
    )
    progression_functions = {
        name
        for name, body in functions.items()
        if TRANSACTION_PROGRESSION.search(body)
        or any(
            re.search(rf"(?<!::)(?<!\.)\b{re.escape(alias)}\s*\(", body)
            for alias in aliases
        )
    }
    changed = True
    while changed:
        changed = False
        for name, body in functions.items():
            if name in progression_functions:
                continue
            if any(
                re.search(
                    rf"(?<![A-Za-z0-9_:])(?:Self::|test_world::)?"
                    rf"{re.escape(callee)}\s*\(",
                    body,
                )
                for callee in progression_functions
            ):
                progression_functions.add(name)
                changed = True
    if progression_functions != APPROVED_WORLD_PROGRESSION_FUNCTIONS:
        return [
            f"{source_path}: World transaction progression functions must be exactly "
            f"{sorted(APPROVED_WORLD_PROGRESSION_FUNCTIONS)}; found "
            f"{sorted(progression_functions)}"
        ]
    return []


def world_constructor_aliases(source: str) -> tuple[set[str], set[str]]:
    namespace_aliases = {"test_world"}
    namespace_aliases.update(
        re.findall(r"\btest_world\s+as\s+([a-z][a-z0-9_]*)\b", source)
    )
    function_aliases: set[str] = set()
    for group in re.finditer(r"\btest_world\s*::\s*\{(?P<body>[^}]*)\}", source, re.DOTALL):
        body = group.group("body")
        namespace_aliases.update(
            re.findall(r"\bSelf\s+as\s+([a-z][a-z0-9_]*)\b", body)
        )
        for function in re.finditer(r"\bnew\b(?:\s+as\s+([a-z][a-z0-9_]*))?", body):
            function_aliases.add(function.group(1) or "new")
    for function in re.finditer(
        r"\btest_world\s*::\s*new\b(?:\s+as\s+([a-z][a-z0-9_]*))?\s*;",
        source,
    ):
        function_aliases.add(function.group(1) or "new")
    return namespace_aliases, function_aliases


def world_constructor_count(body: str, aliases: tuple[set[str], set[str]]) -> int:
    namespace_aliases, function_aliases = aliases
    count = sum(
        len(re.findall(rf"\b{re.escape(alias)}\s*::\s*new\s*\(", body))
        for alias in namespace_aliases
    )
    count += sum(
        len(re.findall(rf"(?<!::)\b{re.escape(alias)}\s*\(", body))
        for alias in function_aliases
    )
    return count


def taxonomy_errors(source_path: str, scope: str, module: str) -> list[str]:
    errors = []
    if scope not in SCOPES:
        errors.append(f"{source_path}: executable module has unknown scope path '{scope}'")
        return errors
    taxonomy = TAXONOMY.fullmatch(module)
    if not taxonomy:
        errors.append(
            f"{source_path}: module '{module}' must match "
            "scope_<scope>__intent_<intent>__<subject>_tests"
        )
        return errors
    if taxonomy.group("scope") != scope:
        errors.append(
            f"{source_path}: module '{module}' must declare path scope '{scope}'"
        )
    expected_markers = [
        f"scope_{taxonomy.group('scope')}__",
        f"intent_{taxonomy.group('intent')}__",
    ]
    if RESERVED_TAXONOMY_MARKER.findall(module) != expected_markers:
        errors.append(f"{source_path}: module '{module}' must contain exactly its two declared markers")
    return errors


def reserved_taxonomy_marker_errors(
    source_path: str,
    source: str,
    module_match: re.Match[str],
) -> list[str]:
    outside_module = source[:module_match.start()] + source[module_match.end():]
    if RESERVED_TAXONOMY_MARKER.search(outside_module):
        return [f"{source_path}: reserved taxonomy markers may appear only in the module name"]
    return []


def successful_test_assertion_errors(source_path: str, source: str) -> list[str]:
    errors = []
    for name, attributes, body, _, _ in attributed_test_records(source):
        if "expected_failure" in attributes:
            continue
        if not DIRECT_ASSERTION.search(body):
            errors.append(
                f"{source_path}::{name}: successful test must contain a direct assert! or assert_eq!"
            )
    return errors


def balanced_call_arguments(source: str, start: int) -> str | None:
    """Return the argument text of a call whose opening paren precedes `start`."""
    depth = 1
    for index in range(start, len(source)):
        character = source[index]
        if character == "(":
            depth += 1
        elif character == ")":
            depth -= 1
            if depth == 0:
                return source[start:index]
    return None


def top_level_arguments(arguments: str) -> list[str]:
    parts: list[str] = []
    depth = 0
    current: list[str] = []
    for character in arguments:
        if character in "([{":
            depth += 1
        elif character in ")]}":
            depth -= 1
        if character == "," and depth == 0:
            parts.append("".join(current).strip())
            current = []
        else:
            current.append(character)
    parts.append("".join(current).strip())
    return parts


def is_atomic_operand(operand: str) -> bool:
    return ATOMIC_OPERAND.fullmatch(operand.strip()) is not None


def vacuous_assertion_errors(source_path: str, source: str) -> list[str]:
    """Reject assertions that cannot fail: assert!(true) and self-comparison of
    one atomic operand (a bare identifier or integer literal). Operands with any
    structure — calls, field or path access, indexing, arithmetic — are exempt
    because evaluating them can have observable effects."""
    errors = []
    for match in ASSERTION_CALL.finditer(source):
        arguments = balanced_call_arguments(source, match.end())
        if arguments is None:
            continue
        parts = top_level_arguments(arguments)
        line = source.count("\n", 0, match.start()) + 1
        if match.group("eq"):
            if (
                len(parts) >= 2
                and parts[0] == parts[1]
                and is_atomic_operand(parts[0])
            ):
                errors.append(
                    f"{source_path}:{line}: vacuous assertion: assert_eq! of the same atomic operand"
                )
            continue
        condition = parts[0] if parts else ""
        if condition == "true":
            errors.append(f"{source_path}:{line}: vacuous assertion: assert!(true)")
            continue
        comparison = re.fullmatch(r"(?P<left>[^=!<>]+)==(?P<right>[^=]+)", condition)
        if (
            comparison
            and comparison.group("left").strip() == comparison.group("right").strip()
            and is_atomic_operand(comparison.group("left"))
        ):
            errors.append(
                f"{source_path}:{line}: vacuous assertion: self-comparison of an atomic operand"
            )
    return errors


def selected_modules(
    executable_tests: list[tuple[str, str, str, tuple[str, ...]]],
    filter_marker: str,
) -> set[str]:
    return {
        module
        for _, _, module, functions in executable_tests
        if any(filter_marker in f"deepbook_predict::{module}::{function}" for function in functions)
    }


def selection_errors(
    executable_tests: list[tuple[str, str, str, tuple[str, ...]]],
) -> list[str]:
    errors = []
    for kind, values in (("scope", SCOPES), ("intent", INTENTS)):
        for value in sorted(values):
            marker = f"{kind}_{value}__"
            expected = {
                module
                for scope, intent, module, _ in executable_tests
                if (scope if kind == "scope" else intent) == value
            }
            actual = selected_modules(executable_tests, marker)
            if actual != expected:
                errors.append(
                    f"filter '{marker}' selects {sorted(actual)}, expected {sorted(expected)}"
                )
    return errors


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
    scenario_world_constructor_count = 0
    executable_tests: list[tuple[str, str, str, tuple[str, ...]]] = []
    for path in move_files:
        text = path.read_text()
        source = source_without_comments(text)
        field_count = scenario_field_count(source)
        if field_count:
            scenario_fields.append((path, field_count))
        if path == world_file:
            scenario_world_constructor_count = scenario_constructor_count(source)
            errors.extend(owned_resources_capability_errors(relative(path), text))
            errors.extend(world_progression_api_errors(relative(path), text))
        elif accesses_scenario_api(source):
            errors.append(f"{relative(path)}: test_world must own all Scenario API access")
        if path != world_file and re.search(r"\btake_shared\s*<", source):
            errors.append(f"{relative(path)}: ambient take_shared<T> is bootstrap-only")
        executable = has_executable_test(source)
        if path != world_file:
            outside_tests = source_outside_test_bodies(source)
            errors.extend(hidden_transaction_progression_errors(relative(path), text))
            aliases = world_constructor_aliases(source)
            if world_constructor_count(outside_tests, aliases):
                errors.append(f"{relative(path)}: test World construction must stay in test bodies")

        if not executable:
            continue
        scope = path.relative_to(TESTS).parts[0]
        module_match = re.search(r"module\s+deepbook_predict::([a-z0-9_]+)\s*;", source)
        if not module_match:
            errors.append(f"{relative(path)}: executable module name is missing or malformed")
            continue
        module = module_match.group(1)
        errors.extend(taxonomy_errors(relative(path), scope, module))
        errors.extend(reserved_taxonomy_marker_errors(relative(path), source, module_match))
        errors.extend(successful_test_assertion_errors(relative(path), source))
        errors.extend(vacuous_assertion_errors(relative(path), source))
        taxonomy = TAXONOMY.fullmatch(module)
        if taxonomy:
            executable_tests.append((
                taxonomy.group("scope"),
                taxonomy.group("intent"),
                module,
                tuple(name for name, _ in attributed_test_bodies(source)),
            ))
        aliases = world_constructor_aliases(source)
        for function, body in attributed_test_bodies(source):
            constructors = world_constructor_count(body, aliases)
            if constructors > 1:
                errors.append(
                    f"{relative(path)}::{function}: expected at most one test World; "
                    f"found {constructors}"
                )

    errors.extend(selection_errors(executable_tests))

    if scenario_fields != [(world_file, 1)]:
        rendered = ", ".join(
            f"{relative(path)} ({count})" for path, count in scenario_fields
        ) or "none"
        errors.append(
            f"Scenario field owner must be exactly {relative(world_file)} (1); found {rendered}"
        )
    if scenario_world_constructor_count != 1:
        errors.append(
            f"{relative(world_file)}: expected exactly one test_scenario constructor; "
            f"found {scenario_world_constructor_count}"
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
