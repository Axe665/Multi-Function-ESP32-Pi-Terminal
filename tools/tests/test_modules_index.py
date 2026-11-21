#!/usr/bin/env python3
"""MODULES.md 是模块命名与身份的权威索引；这里防止索引和目录漂移。"""
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEVKIT = ROOT / "module-devkit"
INDEX = ROOT / "MODULES.md"


def index_rows():
    rows = {}
    for line in INDEX.read_text(encoding="utf-8").splitlines():
        if not line.startswith("| `"):
            continue
        cells = [cell.strip().strip("`") for cell in line.strip().strip("|").split("|")]
        rows[cells[0]] = cells
    return rows


class ModulesIndexTest(unittest.TestCase):
    def setUp(self):
        self.rows = index_rows()

    def examples(self):
        return sorted(p for p in (DEVKIT / "examples").iterdir() if (p / "manifest.json").is_file())

    def test_every_example_is_listed(self):
        for project in self.examples():
            manifest = json.loads((project / "manifest.json").read_text(encoding="utf-8"))
            with self.subTest(module=project.name):
                self.assertIn(project.name, self.rows, "MODULES.md 漏登记")
                row = self.rows[project.name]
                self.assertIn(manifest["name"], row, "中文名不一致")
                self.assertIn(manifest["id"], row, "manifest.id 不一致")
                self.assertIn(str(manifest["module_id"]), row, "module_id 不一致")

    def test_every_example_has_labeled_readme(self):
        for project in self.examples():
            manifest = json.loads((project / "manifest.json").read_text(encoding="utf-8"))
            readme = project / "README.md"
            with self.subTest(module=project.name):
                self.assertTrue(readme.is_file(), "示例缺少 README.md")
                head = "\n".join(readme.read_text(encoding="utf-8").splitlines()[:6])
                self.assertIn("> 模块：" + manifest["name"], head)
                self.assertIn("id %d" % manifest["module_id"], head)
                self.assertIn("形态：", head)

    def test_esp_modules_are_listed_and_labeled(self):
        for project in sorted(p for p in (ROOT / "esp/modules").iterdir() if p.is_dir()):
            with self.subTest(module=project.name):
                self.assertIn(project.name, self.rows, "MODULES.md 漏登记 ESP 模块")
                readme = project / "README.md"
                self.assertTrue(readme.is_file(), "ESP 模块缺少 README.md")
                head = "\n".join(readme.read_text(encoding="utf-8").splitlines()[:6])
                self.assertIn("> 模块：", head)
                self.assertIn("id %s" % self.rows[project.name][3], head)

    def test_module_ids_are_unique(self):
        seen = {}
        for project in self.examples():
            manifest = json.loads((project / "manifest.json").read_text(encoding="utf-8"))
            module_id = manifest["module_id"]
            with self.subTest(module=project.name):
                self.assertNotIn(module_id, seen, "module_id 与 %s 重复" % seen.get(module_id))
                seen[module_id] = project.name


if __name__ == "__main__":
    unittest.main()
