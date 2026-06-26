import ast
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PYPROJECT = ROOT / "pyproject.toml"


def _section(name: str) -> str:
    text = PYPROJECT.read_text()
    match = re.search(
        rf"^\[{re.escape(name)}\]\n(?P<body>.*?)(?=^\[|\Z)",
        text,
        flags=re.MULTILINE | re.DOTALL,
    )
    return match.group("body") if match else ""


def _array_value(section: str, key: str) -> list[str]:
    match = re.search(rf"^{re.escape(key)}\s*=\s*(\[.*?\])\s*$", section, flags=re.MULTILINE)
    if match is None:
        return []
    return ast.literal_eval(match.group(1))


class PackagingTests(unittest.TestCase):
    def test_tx_dependencies_ship_with_base_package(self) -> None:
        dependencies = _array_value(_section("project"), "dependencies")
        optional_dependency_section = _section("project.optional-dependencies")

        self.assertIn("pynacl>=1.5", dependencies)
        self.assertNotRegex(optional_dependency_section, r"^tx\s*=", msg="tx extra should not be required")


if __name__ == "__main__":
    unittest.main()
