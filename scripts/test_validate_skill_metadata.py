#!/usr/bin/env python3
"""Negative regressions for the portable SKILL.md metadata validator."""

import tempfile
import unittest
from pathlib import Path

from scripts.validate_skill_metadata import validate_skill


def skill(frontmatter: str, body: str = "# Instructions\n") -> str:
    return f"---\n{frontmatter}\n---\n{body}"


class SkillMetadataValidationTests(unittest.TestCase):
    def validate(self, content: str) -> tuple[bool, str]:
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "SKILL.md").write_text(content, encoding="utf-8")
            return validate_skill(directory)

    def test_accepts_current_contract(self) -> None:
        valid, _ = self.validate(skill("name: example-skill\ndescription: Useful skill"))
        self.assertTrue(valid)

    def test_rejects_unexpected_compatibility_key(self) -> None:
        valid, _ = self.validate(
            skill("name: example-skill\ndescription: Useful skill\ncompatibility: legacy")
        )
        self.assertFalse(valid)

    def test_rejects_long_name(self) -> None:
        valid, _ = self.validate(skill(f"name: {'a' * 65}\ndescription: Useful skill"))
        self.assertFalse(valid)

    def test_rejects_description_placeholder_and_angle_brackets(self) -> None:
        for description in ("[TODO: finish]", "Use <placeholder>"):
            with self.subTest(description=description):
                valid, _ = self.validate(skill(f"name: example-skill\ndescription: '{description}'"))
                self.assertFalse(valid)

    def test_rejects_bare_body_todo_but_allows_fenced_example(self) -> None:
        invalid, _ = self.validate(
            skill("name: example-skill\ndescription: Useful skill", "# Instructions\n[TODO: finish]\n")
        )
        valid, _ = self.validate(
            skill(
                "name: example-skill\ndescription: Useful skill",
                "# Instructions\n```text\n[TODO: example]\n```\n",
            )
        )
        self.assertFalse(invalid)
        self.assertTrue(valid)


if __name__ == "__main__":
    unittest.main()
